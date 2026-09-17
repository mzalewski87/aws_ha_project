#!/usr/bin/env bash
###############################################################################
# setup-machine-autoenroll.sh — make every domain-joined machine enrol a
# computer certificate from the AD CS issuing CA, without anyone touching it.
#
# This is the client-side half of GlobalProtect pre-logon. Pre-logon
# authenticates the DEVICE, before any user has logged in, using a machine
# certificate; if machines do not get one automatically, pre-logon degrades into
# a manual per-machine chore and the whole point is lost.
#
# Two things are needed and the default install has neither:
#
#   1. The "Machine" (Computer) template grants Domain Computers the Enroll
#      right but NOT Autoenroll. Enroll alone means "may request if asked" —
#      nothing ever asks. Autoenroll is a separate extended right.
#   2. The autoenrollment client must be switched on by policy (AEPolicy).
#      Without it the machine never runs the enrolment task at all.
#
# Both are set here: the extended right on the template object in the
# configuration partition, and AEPolicy in the Default Domain Policy.
#
# Env: AWS_REGION, DC_INSTANCE_ID, DOMAIN, DOMAIN_ADMIN, DOMAIN_PASSWORD
###############################################################################
set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
DC_ID="${DC_INSTANCE_ID:?DC_INSTANCE_ID required}"
DOMAIN="${DOMAIN:?DOMAIN required}"
DA="${DOMAIN_ADMIN:?DOMAIN_ADMIN required}"
DP="${DOMAIN_PASSWORD:?DOMAIN_PASSWORD required}"
GPO_NAME="${GPO_NAME:-Default Domain Policy}"
# Optional: a plain MEMBER SERVER to test enrolment on. A domain controller
# cannot be used - DCs sit in Domain Controllers, not Domain Computers, so the
# Machine template permission granted below simply does not apply to them and
# the test fails with CERTSRV_E_TEMPLATE_DENIED while everything is fine.
CANARY_ID="${CANARY_INSTANCE_ID:-}"
POLL_MAX="${POLL_MAX:-900}"
TARGET_ID="${TARGET_ID:-}"

say() { printf '[autoenroll] %s\n' "$*"; }

run_ps() { # $1 = powershell, $2 = label; targets $TARGET_ID (default: the DC)
  local ps="$1" label="$2" cid pfile status out
  local DC_ID="${TARGET_ID:-$DC_ID}"
  pfile="/tmp/autoenroll-${label}.json"
  printf '%s' "$ps" | jq -R -s '{commands: (rtrimstr("\n") | split("\n"))}' > "$pfile"
  if ! cid="$(aws ssm send-command --region "$REGION" --instance-ids "$DC_ID" \
        --document-name AWS-RunPowerShellScript --parameters "file://${pfile}" \
        --timeout-seconds 600 --query 'Command.CommandId' --output text 2>&1)"; then
    echo "[autoenroll] send-command failed ($label): $cid" >&2; exit 1
  fi
  local deadline=$(( $(date +%s) + POLL_MAX ))
  while :; do
    status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
              --instance-id "$DC_ID" --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in Success|Failed|TimedOut|Cancelled) break ;; esac
    [ "$(date +%s)" -ge "$deadline" ] && { echo "[autoenroll] $label still running" >&2; exit 1; }
    sleep 10
  done
  out="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
        --instance-id "$DC_ID" --query 'StandardOutputContent' --output text 2>/dev/null || true)"
  if [ "$status" != "Success" ]; then
    echo "[autoenroll] STEP FAILED ($label): $status" >&2
    printf '%s\n' "$out" >&2
    aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
      --instance-id "$DC_ID" --query 'StandardErrorContent' --output text 2>/dev/null >&2 || true
    exit 1
  fi
  printf '%s' "$out"
}

# Run a payload under a DOMAIN ADMIN token. SSM RunCommand executes as
# NT AUTHORITY\SYSTEM, which on a domain controller is the COMPUTER account.
# That is enough to read the configuration partition but not to write it, so
# editing a certificate template ACL fails with a bare "Set-Acl : Access is
# denied" and editing a GPO fails the same way. A scheduled task is the one
# mechanism available over SSM that yields a real domain-admin token.
#
# The payload goes to a FILE, not into the task argument string: Task Scheduler
# mangles long arguments containing redirections, producing an empty log and no
# error. And the wait is on the task State, not LastTaskResult — right after
# Start the latter still holds the PREVIOUS run, so polling it races.
run_ps_admin() { # $1 = powershell, $2 = label
  local ps="$1" label="$2" b64
  b64="$(printf '%s' "$ps" | base64 | tr -d '\n')"
  run_ps "
\$ErrorActionPreference='Stop'
\$body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${b64}'))
Set-Content -Path 'C:\\ae-step.ps1' -Value \$body -Encoding UTF8
Remove-Item 'C:\\ae-step.log' -ErrorAction SilentlyContinue
\$a = New-ScheduledTaskAction -Execute 'powershell.exe' \`
     -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\\ae-step.ps1'
Register-ScheduledTask -TaskName 'ae-step' -Action \$a \`
  -User '${DA}@${DOMAIN}' -Password '${DP}' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'ae-step'
\$deadline = (Get-Date).AddMinutes(10)
Start-Sleep -Seconds 5
do {
  Start-Sleep -Seconds 5
  \$t = Get-ScheduledTask -TaskName 'ae-step'
} while (\$t.State -eq 'Running' -and (Get-Date) -lt \$deadline)
Unregister-ScheduledTask -TaskName 'ae-step' -Confirm:\$false
Get-Content 'C:\\ae-step.log' -ErrorAction SilentlyContinue | Out-String
" "$label"
}

# NOTE: no unescaped double quotes inside these payloads. They are passed as
# double-quoted bash arguments, so a bare quote ends the argument early and
# silently shifts every argument after it.

say "granting Autoenroll on the Machine template + enabling the autoenrollment policy"
run_ps_admin "
\$ErrorActionPreference='Stop'
Import-Module ActiveDirectory
\$cfg = (Get-ADRootDSE).configurationNamingContext
\$tpl = 'CN=Machine,CN=Certificate Templates,CN=Public Key Services,CN=Services,' + \$cfg
# 0e10c968-... = Enroll, a05b8cc2-... = Autoenroll. The template ships with the
# first and not the second, which is why nothing enrols on its own.
\$autoenroll = [Guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'
\$sid  = (Get-ADGroup 'Domain Computers').SID
\$path = 'AD:' + \$tpl
\$acl  = Get-Acl -Path \$path
\$have = \$acl.Access | Where-Object {
  \$_.IdentityReference -like '*Domain Computers*' -and \$_.ObjectType -eq \$autoenroll }
\$o = @()
if (\$have) {
  \$o += 'AUTOENROLL=already granted'
} else {
  \$rule = New-Object DirectoryServices.ActiveDirectoryAccessRule(
    \$sid, 'ExtendedRight', 'Allow', \$autoenroll)
  \$acl.AddAccessRule(\$rule)
  Set-Acl -Path \$path -AclObject \$acl
  \$o += 'AUTOENROLL=granted'
}
# AEPolicy bits: 1 = enrol automatically, 2 = renew expired / clean up revoked,
# 4 = update certificates that use templates. 7 = all three, which is what the
# GUI produces with every box ticked. Without this the client never runs the
# enrolment task at all, however the template is permissioned.
Import-Module GroupPolicy
Set-GPRegistryValue -Name '${GPO_NAME}' \`
  -Key 'HKLM\\Software\\Policies\\Microsoft\\Cryptography\\AutoEnrollment' \`
  -ValueName 'AEPolicy' -Type DWord -Value 7 | Out-Null
gpupdate /force | Out-Null
\$v = Get-GPRegistryValue -Name '${GPO_NAME}' \`
  -Key 'HKLM\\Software\\Policies\\Microsoft\\Cryptography\\AutoEnrollment'
\$o += 'AEPOLICY=' + (\$v | Where-Object { \$_.ValueName -eq 'AEPolicy' }).Value
\$o | Out-File C:\\ae-step.log -Encoding ascii
" "template-acl"

if [ -n "$CANARY_ID" ]; then
  say "verifying a member server can enrol (canary: $CANARY_ID)"
  CANARY_OUT="$(TARGET_ID="$CANARY_ID" run_ps "
\$ErrorActionPreference='Continue'
# The CA caches template permissions; without a pulse the first enrolment after
# an ACL change can still be refused.
certutil -pulse 2>&1 | Out-Null
certreq -machine -q -enroll Machine 2>&1 | Out-String
\$c = Get-ChildItem Cert:\\LocalMachine\\My |
     Where-Object { \$_.Issuer -like '*Issuing CA*' } | Select-Object -First 1
if (\$c) { 'MACHINE_CERT=' + \$c.Subject + ' issuer=' + \$c.Issuer } else { 'MACHINE_CERT=none' }
" "canary")"
  printf '%s\n' "$CANARY_OUT" | sed 's/^/[autoenroll]   /'
  case "$CANARY_OUT" in
    *"MACHINE_CERT=CN="*) say "enrolment works" ;;
    *) echo "[autoenroll] the canary did not get a certificate — see above" >&2; exit 1 ;;
  esac
fi

say "done. Domain members pick a machine certificate up at their next policy refresh."
say "On a client, force it now with:  gpupdate /force  (then certlm.msc -> Personal)"
