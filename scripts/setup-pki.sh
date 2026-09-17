#!/usr/bin/env bash
###############################################################################
# setup-pki.sh — build the two-tier AD CS chain and hand PAN-OS its own
# subordinate CA for SSL Forward Proxy.
#
# Everything runs through SSM RunCommand; neither CA host has an inbound
# administrative path. The CSR and the signed certificate are shuttled between
# hosts as base64 through command output — they are a few KB and contain no
# private key, so this needs no shared storage.
#
# Order matters and each step is idempotent enough to re-run:
#
#   1. wait for both CA hosts to answer SSM
#   2. issuing CA: install the role -> it emits a CSR
#   3. root CA: sign the CSR as a subordinate CA, and export its cert + CRL
#   4. publish the ROOT cert and CRL into AD
#   5. issuing CA: install the signed cert, start the service
#   6. stop the root CA — it has signed the only thing it ever needs to
#
# Step 4 must precede step 5. Installing the signed certificate validates the
# whole chain, revocation included, and the root's CRL distribution points name
# an offline, non domain-joined host — so without a CRL in AD the install hangs
# on network timeouts rather than failing with anything you can read.
#
# PAN-OS's own subordinate CA is issued separately by setup-ssl-decrypt.sh,
# which runs after this.
#
# Env: AWS_REGION, ROOT_CA_ID, SUB_CA_ID, DOMAIN, DOMAIN_ADMIN, DOMAIN_PASSWORD
###############################################################################
set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
ROOT_ID="${ROOT_CA_ID:?ROOT_CA_ID required}"
SUB_ID="${SUB_CA_ID:?SUB_CA_ID required}"
DOMAIN="${DOMAIN:?DOMAIN required}"
DA="${DOMAIN_ADMIN:?DOMAIN_ADMIN required}"
DP="${DOMAIN_PASSWORD:?DOMAIN_PASSWORD required}"
SUB_CN="${SUB_CA_CN:-PANW Lab Issuing CA}"
POLL_MAX="${PKI_POLL_MAX:-1800}"   # how long any single step may run

say() { printf '[pki] %s\n' "$*"; }

# Run PowerShell on an instance and print stdout. Fails loudly: a silent
# RunCommand failure here would leave a half-built CA that is worse than none.
# SSM's `commands` is a LIST — one element per line. Passing the whole script as
# a single JSON string (jq -Rs '[.]') sends it as ONE line containing literal
# \n characters, and PowerShell then dies with MissingEndCurlyBrace on the first
# multi-line block. Split on newlines instead.
run_ps() { # $1 = instance, $2 = powershell, $3 = label, $4 = timeout secs
  local inst="$1" ps="$2" label="$3" tmo="${4:-600}"
  local cid
  cid="$(aws ssm send-command --region "$REGION" --instance-ids "$inst" \
        --document-name AWS-RunPowerShellScript \
        --parameters "commands=$(printf '%s' "$ps" | jq -R -s 'rtrimstr("\n") | split("\n")')" \
        --timeout-seconds "$tmo" \
        --query 'Command.CommandId' --output text)"
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
      echo "[pki] inspect with: aws ssm get-command-invocation --region $REGION --command-id $cid --instance-id $inst" >&2
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

# --- 2. issuing CA: install role, produce a CSR ------------------------------
# Install-AdcsCertificationAuthority for a subordinate returns exit code 398
# ("the CA requires a certificate") — that is SUCCESS with a pending request,
# not an error, so it must not abort the script.
say "installing enterprise subordinate CA role (emits a CSR)"
run_ps "$SUB_ID" "
\$ErrorActionPreference='Continue'
if (-not (Get-WindowsFeature AD-Certificate).Installed) {
  Install-WindowsFeature AD-Certificate, RSAT-ADCS -IncludeManagementTools | Out-Null
}
\$pw   = ConvertTo-SecureString '${DP}' -AsPlainText -Force
\$cred = New-Object System.Management.Automation.PSCredential('${DA}@${DOMAIN}', \$pw)
if (-not (Test-Path 'C:\\*.req')) {
  Install-AdcsCertificationAuthority \`
    -CAType EnterpriseSubordinateCA \`
    -CACommonName '${SUB_CN}' \`
    -KeyLength 4096 -HashAlgorithmName SHA256 \`
    -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' \`
    -Credential \$cred -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
}
\$req = Get-ChildItem 'C:\\*.req' | Select-Object -First 1
if (-not \$req) { Write-Error 'no CSR produced'; exit 1 }
'---B64BEGIN---'
[Convert]::ToBase64String([IO.File]::ReadAllBytes(\$req.FullName))
'---B64END---'
" "sub-ca-role" 900 | b64_between > /tmp/pki-sub.csr.b64
say "CSR captured ($(wc -c < /tmp/pki-sub.csr.b64) b64 bytes)"

# --- 3. root CA: sign it -----------------------------------------------------
say "signing the issuing CA certificate on the offline root"
run_ps "$ROOT_ID" "
\$ErrorActionPreference='Stop'
\$b64 = '$(cat /tmp/pki-sub.csr.b64)'
[IO.File]::WriteAllBytes('C:\\sub.req', [Convert]::FromBase64String(\$b64))
Remove-Item 'C:\\sub.cer','C:\\sub.rsp' -ErrorAction SilentlyContinue
# -config MUST be explicit. 'certreq -config -' opens the interactive CA picker,
# which under SSM (session 0, no desktop) blocks until the command times out.
# The CA's sanitised name lives in the CertSvc 'Active' registry value.
\$ca = (Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\CertSvc\\Configuration').Active
\$cfg = \"\$env:COMPUTERNAME\\\$ca\"
# A standalone CA holds every request pending (disposition 9) and expects a human
# in the CA console. There is no human here, and the pending->resubmit dance is
# fragile: a request that has been touched wrongly once goes to Denied and can
# never be resubmitted. Tell the CA to issue immediately instead. This is safe
# for THIS CA specifically: it is an offline root that signs exactly one
# certificate and is powered off at the end of this script.
certutil -setreg policy\\RequestDisposition 1 2>&1 | Out-Null
Restart-Service certsvc
Start-Sleep -Seconds 10
# -q suppresses the remaining prompts; the SubCA attrib is ignored by a
# standalone CA but is correct if this root is ever made enterprise.
\$out = certreq -q -config \$cfg -submit -attrib 'CertificateTemplate:SubCA' 'C:\\sub.req' 'C:\\sub.cer' 2>&1 | Out-String
if (-not (Test-Path 'C:\\sub.cer')) {
  # Still pending: approve by id and fetch. The stale .rsp must go first -
  # certreq prompts 'overwrite?' on an existing one even under -q, and that
  # prompt is unanswerable here, so the retrieve fails with ERROR_FILE_EXISTS.
  \$m = [regex]::Match(\$out, 'RequestId:\\s*\"?(\\d+)')
  if (\$m.Success) {
    \$id = \$m.Groups[1].Value
    Remove-Item 'C:\\sub.rsp' -ErrorAction SilentlyContinue
    \$out += (certutil -config \$cfg -resubmit \$id 2>&1 | Out-String)
    Start-Sleep -Seconds 5
    Remove-Item 'C:\\sub.rsp' -ErrorAction SilentlyContinue
    \$out += (certreq -q -config \$cfg -retrieve \$id 'C:\\sub.cer' 2>&1 | Out-String)
  }
}
if (-not (Test-Path 'C:\\sub.cer')) { Write-Error \"signing failed: \$out\"; exit 1 }
'---B64BEGIN---'
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\\sub.cer'))
'---B64END---'
" "root-sign" 600 | b64_between > /tmp/pki-sub.cer.b64
say "issuing CA certificate signed"

# also grab the root certificate itself — needed for the AD trust publication
run_ps "$ROOT_ID" "
\$c = Get-ChildItem Cert:\\LocalMachine\\CA,Cert:\\LocalMachine\\Root |
      Where-Object { \$_.Subject -like '*${CA_ROOT_CN:-PANW Lab Root CA}*' } | Select-Object -First 1
if (-not \$c) { Write-Error 'root cert not found'; exit 1 }
'---B64BEGIN---'
[Convert]::ToBase64String(\$c.RawData)
'---B64END---'
" "root-cert" 300 | b64_between > /tmp/pki-root.cer.b64

# ...and its CRL. This is not optional. Installing the signed certificate on the
# issuing CA triggers a full chain validation, which includes a revocation check
# against the root's CRL distribution points. Those point at an offline, non
# domain-joined machine, so every check sits there timing out and
# `certutil -installcert` hangs indefinitely with no error to read. Publishing
# the CRL into AD (next step) gives the chain engine something reachable.
say "generating and fetching the root CRL"
run_ps "$ROOT_ID" "
\$ErrorActionPreference='Stop'
certutil -CRL 2>&1 | Out-Null
\$crl = Get-ChildItem 'C:\\Windows\\System32\\CertSrv\\CertEnroll\\*.crl' |
        Sort-Object LastWriteTime | Select-Object -Last 1
if (-not \$crl) { Write-Error 'no CRL produced'; exit 1 }
'---B64BEGIN---'
[Convert]::ToBase64String([IO.File]::ReadAllBytes(\$crl.FullName))
'---B64END---'
" "root-crl" 300 | b64_between > /tmp/pki-root.crl.b64

# --- 4. publish the ROOT (cert + CRL) into AD --------------------------------
# Order matters: this MUST happen before the install below. It is what makes the
# client side hands-off (-dspublish writes the root into the forest's
# Certification Authorities container, so every domain-joined machine pulls it
# into its Trusted Root store on the next policy refresh) AND what stops the
# install from hanging, by giving the chain engine an ldap:/// CRL it can
# actually reach.
say "publishing the root CA and its CRL into Active Directory"
run_ps "$SUB_ID" "
\$ErrorActionPreference='Stop'
[IO.File]::WriteAllBytes('C:\\root.cer', [Convert]::FromBase64String('$(cat /tmp/pki-root.cer.b64)'))
[IO.File]::WriteAllBytes('C:\\root.crl', [Convert]::FromBase64String('$(cat /tmp/pki-root.crl.b64)'))
# trusted locally first - a child certificate will not install under an untrusted root
certutil -addstore -f Root 'C:\\root.cer' | Out-Null
certutil -addstore -f Root 'C:\\root.crl' | Out-Null
certutil -dspublish -f 'C:\\root.cer' RootCA   | Out-Null
certutil -dspublish -f 'C:\\root.cer' NTAuthCA | Out-Null
certutil -dspublish -f 'C:\\root.crl'          | Out-Null
# drop any cached 'revocation unavailable' verdict from the failed attempts
certutil -setreg chain\\ChainCacheResyncFiletime @now 2>&1 | Out-Null
gpupdate /force | Out-Null
'published'
" "ad-publish" 600

# --- 5. issuing CA: install the signed certificate ---------------------------
say "installing the signed certificate on the issuing CA"
run_ps "$SUB_ID" "
\$ErrorActionPreference='Stop'
[IO.File]::WriteAllBytes('C:\\sub.cer', [Convert]::FromBase64String('$(cat /tmp/pki-sub.cer.b64)'))
certutil -f -installcert 'C:\\sub.cer' 2>&1 | Out-String
Start-Service certsvc
Start-Sleep -Seconds 15
\$st = (Get-Service certsvc).Status
if (\$st -ne 'Running') { Write-Error \"certsvc is \$st\"; exit 1 }
'CERTSVC=' + \$st
" "sub-install" 900
say "issuing CA service started"

# --- 6. take the root offline ------------------------------------------------
say "stopping the root CA — its job is done until the issuing CA needs renewal"
aws ec2 stop-instances --region "$REGION" --instance-ids "$ROOT_ID" \
  --query 'StoppingInstances[0].CurrentState.Name' --output text

say "two-tier PKI ready. Root is offline; issuing CA is live and published to AD."
