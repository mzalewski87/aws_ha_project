#!/usr/bin/env bash
###############################################################################
# setup-pki.sh — build the two-tier AD CS chain that anchors SSL Forward Proxy
# and GlobalProtect pre-logon machine certificates.
#
# Everything runs through SSM RunCommand; neither CA host has an inbound
# administrative path. The CSR, the signed certificate and the root CRL are
# shuttled between hosts as base64 through command output — a few KB each, no
# private key, so this needs no shared storage.
#
#   1. wait for both CA hosts to answer SSM
#   2. root CA: switch to automatic issuance, refresh its CRL
#   3. export the root certificate and CRL
#   4. publish both into AD
#   5. issuing CA: install the role -> it emits a CSR
#   6. root CA: sign the CSR as a subordinate CA
#   7. issuing CA: install the signed certificate, start the service
#   8. stop the root CA — it has signed the only thing it ever needs to
#
# Step 4 must precede step 7: installing a subordinate CA certificate validates
# the whole chain, revocation included, and the root's CRL distribution points
# name an offline, non domain-joined host. Without a CRL in AD every lookup sits
# there timing out and the install hangs with nothing to read.
#
# The file-based request/sign/install flow above is not an accident. The tidier
# looking `Install-AdcsCertificationAuthority -ParentCA` cannot work here: it
# submits the request over RPC and has to authenticate to the parent, and the
# root is deliberately in a workgroup, so no shared credential exists. It fails
# with RPC_S_SERVER_UNAVAILABLE even though the RPC ports are wide open.
#
# PAN-OS's own subordinate CA is issued separately by setup-ssl-decrypt.sh,
# which runs after this.
#
# Env: AWS_REGION, ROOT_CA_ID, SUB_CA_ID, DOMAIN, DOMAIN_ADMIN, DOMAIN_PASSWORD
#
# Note: no apostrophes in ${VAR:?message} text. bash parses quotes inside the
# message, so a lone ' opens a string that swallows the following lines into the
# variable - and it passes `bash -n` cleanly.
###############################################################################
set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
ROOT_ID="${ROOT_CA_ID:?ROOT_CA_ID required}"
SUB_ID="${SUB_CA_ID:?SUB_CA_ID required}"
DOMAIN="${DOMAIN:?DOMAIN required}"
DA="${DOMAIN_ADMIN:?DOMAIN_ADMIN required}"
DP="${DOMAIN_PASSWORD:?DOMAIN_PASSWORD required}"
SUB_CN="${SUB_CA_CN:-PANW Lab Issuing CA}"
ROOT_CN="${CA_ROOT_CN:-PANW Lab Root CA}"
POLL_MAX="${PKI_POLL_MAX:-1800}"   # how long any single step may run

say() { printf '[pki] %s\n' "$*"; }

# Run PowerShell on an instance and print stdout. Fails loudly: a silent
# RunCommand failure here would leave a half-built CA, which is worse than none.
#
# SSM's `commands` is a LIST — one element per line. Passing the whole script as
# a single JSON string (the jq -Rs '[.]' pattern) sends it as ONE line containing
# literal \n characters, and PowerShell then dies with MissingEndCurlyBrace on
# the first multi-line block. Split on newlines instead.
run_ps() { # $1 = instance, $2 = powershell, $3 = label, $4 = delivery timeout
  local inst="$1" ps="$2" label="$3" tmo="${4:-600}"
  local cid pfile
  # Pass real JSON via a file rather than the CLI shorthand. `--parameters
  # "commands=[...]"` goes through the shorthand parser, which re-reads the
  # payload looking for key=value pairs and list indices and falls over on
  # ordinary script text with errors that name nothing in the script
  # ("invalid literal for int() with base 10: 'key'"). A JSON file bypasses it.
  pfile="/tmp/pki-params-${label}.json"
  printf '%s' "$ps" | jq -R -s '{commands: (rtrimstr("\n") | split("\n"))}' > "$pfile" || {
    echo "[pki] could not build the parameter JSON for $label" >&2; exit 1; }
  if ! cid="$(aws ssm send-command --region "$REGION" --instance-ids "$inst" \
        --document-name AWS-RunPowerShellScript \
        --parameters "file://${pfile}" \
        --timeout-seconds "$tmo" \
        --query 'Command.CommandId' --output text 2>&1)"; then
    echo "[pki] send-command failed for $label: $cid" >&2
    echo "[pki] payload left at $pfile for inspection" >&2
    exit 1
  fi
  # --timeout-seconds bounds DELIVERY, not execution: a command can legitimately
  # run for longer, so poll against our own deadline rather than reusing $tmo.
  local status="" deadline=$(( $(date +%s) + POLL_MAX ))
  while :; do
    status="$(aws ssm get-command-invocation --region "$REGION" \
              --command-id "$cid" --instance-id "$inst" \
              --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in Success|Failed|TimedOut|Cancelled) break ;; esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "[pki] STEP STILL RUNNING after ${POLL_MAX}s ($label), command $cid" >&2
      echo "[pki] inspect: aws ssm get-command-invocation --region $REGION --command-id $cid --instance-id $inst" >&2
      exit 1
    fi
    sleep 10
  done
  local out err
  out="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
        --instance-id "$inst" --query 'StandardOutputContent' --output text 2>/dev/null || true)"
  if [ "$status" != "Success" ]; then
    err="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
          --instance-id "$inst" --query 'StandardErrorContent' --output text 2>/dev/null || true)"
    echo "[pki] STEP FAILED ($label): $status" >&2
    printf '%s\n%s\n' "$out" "$err" >&2
    exit 1
  fi
  printf '%s' "$out"
}

# Run PowerShell on the issuing CA under a DOMAIN ADMIN token, and return its
# output. SSM RunCommand executes as NT AUTHORITY\SYSTEM, which is fine for
# almost everything but not for `certutil -installcert`: that is checked against
# the CA's own security descriptor, which grants "Manage CA" to administrators
# and to Enterprise/Domain Admins but NOT to SYSTEM. The symptom is a bare
# "CertUtil: -installCert command FAILED: 0x80070005 (ERROR_ACCESS_DENIED)",
# which reads like a file-permission problem and is not one.
#
# A scheduled task is the one mechanism available here that yields a real
# domain-admin token. The payload goes to a FILE rather than into the task's
# argument string: Task Scheduler mangles long arguments containing
# redirections, which silently produces an empty log and no error at all.
run_ps_admin() { # $1 = powershell, $2 = label
  local ps="$1" label="$2" b64
  b64="$(printf '%s' "$ps" | base64 | tr -d '\n')"
  run_ps "$SUB_ID" "
\$ErrorActionPreference='Stop'
\$body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${b64}'))
Set-Content -Path 'C:\\pki-step.ps1' -Value \$body -Encoding UTF8
Remove-Item 'C:\\pki-step.log' -ErrorAction SilentlyContinue
\$a = New-ScheduledTaskAction -Execute 'powershell.exe' \`
     -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\\pki-step.ps1'
Register-ScheduledTask -TaskName 'pki-step' -Action \$a \`
  -User '${DA}@${DOMAIN}' -Password '${DP}' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'pki-step'
# Wait on State, not LastTaskResult: right after Start the task may not have
# transitioned to Running yet, and LastTaskResult still holds the PREVIOUS run,
# so polling that races and tears the task down mid-flight.
\$deadline = (Get-Date).AddMinutes(15)
Start-Sleep -Seconds 5
do {
  Start-Sleep -Seconds 5
  \$t = Get-ScheduledTask -TaskName 'pki-step'
} while (\$t.State -eq 'Running' -and (Get-Date) -lt \$deadline)
Unregister-ScheduledTask -TaskName 'pki-step' -Confirm:\$false
Get-Content 'C:\\pki-step.log' -ErrorAction SilentlyContinue | Out-String
" "$label" 900
}

# Extract only what sits between the markers. RunCommand output is a shared
# stream: Install-AdcsCertificationAuthority emits a WARNING ("the installation
# is incomplete...") that otherwise ends up concatenated with the base64 and
# makes it undecodable. Never parse raw RunCommand stdout as data.
b64_between() { sed -n '/---B64BEGIN---/,/---B64END---/p' | sed '1d;$d' | tr -d '\r\n '; }

wait_ssm() { # $1 = instance, $2 = label
  say "waiting for SSM on $2 ($1)"
  for _ in $(seq 1 80); do
    [ "$(aws ssm describe-instance-information --region "$REGION" \
         --filters "Key=InstanceIds,Values=$1" \
         --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" = "Online" ] \
      && { say "$2 is Online"; return 0; }
    sleep 15
  done
  echo "[pki] $2 never came Online" >&2; exit 1
}

# --- 1. both hosts reachable -------------------------------------------------
wait_ssm "$ROOT_ID" "root CA"
wait_ssm "$SUB_ID"  "issuing CA"

# --- 2. root CA: issue automatically, refresh the CRL ------------------------
# A standalone CA holds every request pending and expects a human in the CA
# console. There is no human here, and the pending->resubmit dance is fragile: a
# request mishandled once lands in Denied and can never be resubmitted. Tell the
# CA to issue immediately instead. That is safe for THIS CA specifically - it is
# an offline root that signs exactly one certificate and is powered off at the
# end of this script.
say "configuring the root CA to issue automatically"
run_ps "$ROOT_ID" "
\$ErrorActionPreference='Stop'
certutil -setreg policy\\RequestDisposition 1 2>&1 | Out-Null
Restart-Service certsvc
Start-Sleep -Seconds 10
certutil -CRL 2>&1 | Out-Null
'ok'
" "root-autoissue" 300

# --- 3. export the root certificate and CRL ----------------------------------
say "exporting the root certificate and CRL"
run_ps "$ROOT_ID" "
\$ErrorActionPreference='Stop'
\$c = Get-ChildItem Cert:\\LocalMachine\\CA,Cert:\\LocalMachine\\Root |
      Where-Object { \$_.Subject -like '*${ROOT_CN}*' } | Select-Object -First 1
if (-not \$c) { Write-Error 'root cert not found'; exit 1 }
'---B64BEGIN---'
[Convert]::ToBase64String(\$c.RawData)
'---B64END---'
" "root-cert" 300 | b64_between > /tmp/pki-root.cer.b64

run_ps "$ROOT_ID" "
\$ErrorActionPreference='Stop'
\$crl = Get-ChildItem 'C:\\Windows\\System32\\CertSrv\\CertEnroll\\*.crl' |
        Sort-Object LastWriteTime | Select-Object -Last 1
if (-not \$crl) { Write-Error 'no CRL produced'; exit 1 }
'---B64BEGIN---'
[Convert]::ToBase64String([IO.File]::ReadAllBytes(\$crl.FullName))
'---B64END---'
" "root-crl" 300 | b64_between > /tmp/pki-root.crl.b64

# --- 4. publish the ROOT (cert + CRL) into AD --------------------------------
# This is what makes the client side hands-off: -dspublish writes the root into
# the forest's Certification Authorities container, so every domain-joined
# machine pulls it into its Trusted Root store on the next policy refresh. It is
# also what keeps step 7 from hanging (see the header).
say "publishing the root CA and its CRL into Active Directory"
run_ps "$SUB_ID" "
\$ErrorActionPreference='Stop'
[IO.File]::WriteAllBytes('C:\\root.cer', [Convert]::FromBase64String('$(cat /tmp/pki-root.cer.b64)'))
[IO.File]::WriteAllBytes('C:\\root.crl', [Convert]::FromBase64String('$(cat /tmp/pki-root.crl.b64)'))
certutil -addstore -f Root 'C:\\root.cer' | Out-Null
certutil -addstore -f Root 'C:\\root.crl' | Out-Null
certutil -dspublish -f 'C:\\root.cer' RootCA   | Out-Null
certutil -dspublish -f 'C:\\root.cer' NTAuthCA | Out-Null
certutil -dspublish -f 'C:\\root.crl'          | Out-Null
# drop any cached 'revocation unavailable' verdict from an earlier attempt
certutil -setreg chain\\ChainCacheResyncFiletime @now 2>&1 | Out-Null
gpupdate /force | Out-Null
'published'
" "ad-publish" 600

# --- 5. issuing CA: install the role, producing a CSR ------------------------
# Install-AdcsCertificationAuthority for a subordinate returns 398 ("the CA
# requires a certificate") — that is SUCCESS with a pending request, not an
# error, so it must not abort the script. An empty payload back means the CA is
# already up and there is nothing to sign.
say "installing enterprise subordinate CA role (emits a CSR)"
run_ps "$SUB_ID" "
\$ErrorActionPreference='Continue'
if (-not (Get-WindowsFeature AD-Certificate).Installed) {
  Install-WindowsFeature AD-Certificate, RSAT-ADCS -IncludeManagementTools | Out-Null
}
\$svc = Get-Service certsvc -ErrorAction SilentlyContinue
if (\$svc -and \$svc.Status -eq 'Running') { '---B64BEGIN---'; '---B64END---'; exit 0 }
\$pw   = ConvertTo-SecureString '${DP}' -AsPlainText -Force
\$cred = New-Object System.Management.Automation.PSCredential('${DA}@${DOMAIN}', \$pw)
if (-not (Get-ChildItem 'C:\\*.req' -ErrorAction SilentlyContinue)) {
  # -OverwriteExistingKey is not optional on a re-run. Uninstalling the CA role
  # does NOT delete its private key from the machine key store, so a second
  # install aborts with a the-private-key-already-exists error and produces no
  # CSR. -OverwriteExistingCAinDS does the same for the CA object in AD.
  # (No double quotes anywhere in this block: it is passed as a double-quoted
  # bash argument, so a bare quote ends it early and silently shifts every
  # following argument -- the label and the timeout land on script text.)
  Install-AdcsCertificationAuthority \`
    -CAType EnterpriseSubordinateCA \`
    -CACommonName '${SUB_CN}' \`
    -KeyLength 4096 -HashAlgorithmName SHA256 \`
    -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' \`
    -OverwriteExistingKey -OverwriteExistingCAinDS \`
    -Credential \$cred -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
}
\$req = Get-ChildItem 'C:\\*.req' | Select-Object -First 1
if (-not \$req) { Write-Error 'no CSR produced'; exit 1 }
'---B64BEGIN---'
[Convert]::ToBase64String([IO.File]::ReadAllBytes(\$req.FullName))
'---B64END---'
" "sub-ca-role" 900 | b64_between > /tmp/pki-sub.csr.b64

if [ ! -s /tmp/pki-sub.csr.b64 ]; then
  say "issuing CA already holds its certificate — skipping sign/install"
else
  say "CSR captured ($(wc -c < /tmp/pki-sub.csr.b64) b64 bytes)"

  # --- 6. root CA: sign it ---------------------------------------------------
  say "signing the issuing CA certificate on the offline root"
  run_ps "$ROOT_ID" "
\$ErrorActionPreference='Stop'
[IO.File]::WriteAllBytes('C:\\sub.req', [Convert]::FromBase64String('$(cat /tmp/pki-sub.csr.b64)'))
Remove-Item 'C:\\sub.cer','C:\\sub.rsp' -ErrorAction SilentlyContinue
# -config MUST be explicit. 'certreq -config -' opens the interactive CA picker,
# which under SSM (session 0, no desktop) blocks until the command times out.
\$ca = (Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\CertSvc\\Configuration').Active
\$cfg = \"\$env:COMPUTERNAME\\\$ca\"
# -q suppresses the remaining prompts; the SubCA attrib is ignored by a
# standalone CA but is correct if this root is ever made enterprise.
\$out = certreq -q -config \$cfg -submit -attrib 'CertificateTemplate:SubCA' 'C:\\sub.req' 'C:\\sub.cer' 2>&1 | Out-String
if (-not (Test-Path 'C:\\sub.cer')) { Write-Error \"signing failed: \$out\"; exit 1 }
'---B64BEGIN---'
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\\sub.cer'))
'---B64END---'
" "root-sign" 600 | b64_between > /tmp/pki-sub.cer.b64
  say "issuing CA certificate signed"

  # --- 7. issuing CA: install the signed certificate -------------------------
  run_ps "$SUB_ID" "
[IO.File]::WriteAllBytes('C:\\sub.cer', [Convert]::FromBase64String('$(cat /tmp/pki-sub.cer.b64)'))
'staged'
" "stage-cert" 300 >/dev/null

  say "installing the signed certificate on the issuing CA (as domain admin)"
  INSTALL_OUT="$(run_ps_admin "\$o = @()
\$o += 'WHOAMI=' + (whoami)
\$o += (certutil -f -installcert C:\\sub.cer 2>&1 | Out-String)
\$o += 'INSTALLCERT_EXIT=' + \$LASTEXITCODE
Start-Service certsvc -ErrorAction SilentlyContinue
Start-Sleep -Seconds 20
\$o += 'CERTSVC=' + (Get-Service certsvc).Status
\$o | Out-File C:\\pki-step.log -Encoding ascii" "sub-install")"

  printf '%s\n' "$INSTALL_OUT" | sed 's/^/[pki]   /'
  case "$INSTALL_OUT" in
    *"CERTSVC=Running"*) say "issuing CA service started" ;;
    *) echo "[pki] the issuing CA did not start — see the output above" >&2; exit 1 ;;
  esac
fi

# --- 8. take the root offline ------------------------------------------------
say "stopping the root CA — its job is done until the issuing CA needs renewal"
aws ec2 stop-instances --region "$REGION" --instance-ids "$ROOT_ID" \
  --query 'StoppingInstances[0].CurrentState.Name' --output text

say "two-tier PKI ready. Root is offline; issuing CA is live and published to AD."
