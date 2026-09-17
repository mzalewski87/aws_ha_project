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
#   3. root CA: sign the CSR as a subordinate CA
#   4. issuing CA: install the signed cert, start the service
#   5. publish the ROOT into AD so every domain member trusts it automatically
#   6. stop the root CA — it has signed the only thing it ever needs to
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

say() { printf '[pki] %s\n' "$*"; }

# Run PowerShell on an instance and print stdout. Fails loudly: a silent
# RunCommand failure here would leave a half-built CA that is worse than none.
run_ps() { # $1 = instance, $2 = powershell, $3 = label, $4 = timeout secs
  local inst="$1" ps="$2" label="$3" tmo="${4:-600}"
  local cid
  cid="$(aws ssm send-command --region "$REGION" --instance-ids "$inst" \
        --document-name AWS-RunPowerShellScript \
        --parameters "commands=$(printf '%s' "$ps" | jq -Rs '[.]')" \
        --timeout-seconds "$tmo" \
        --query 'Command.CommandId' --output text)"
  local status=""
  for _ in $(seq 1 "$((tmo / 5))"); do
    status="$(aws ssm get-command-invocation --region "$REGION" \
              --command-id "$cid" --instance-id "$inst" \
              --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in Success|Failed|TimedOut|Cancelled) break ;; esac
    sleep 5
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
    -Credential \$cred -Force -ErrorAction SilentlyContinue | Out-Null
}
\$req = Get-ChildItem 'C:\\*.req' | Select-Object -First 1
if (-not \$req) { Write-Error 'no CSR produced'; exit 1 }
[Convert]::ToBase64String([IO.File]::ReadAllBytes(\$req.FullName))
" "sub-ca-role" 900 | tr -d '\r\n ' > /tmp/pki-sub.csr.b64
say "CSR captured ($(wc -c < /tmp/pki-sub.csr.b64) b64 bytes)"

# --- 3. root CA: sign it -----------------------------------------------------
say "signing the issuing CA certificate on the offline root"
run_ps "$ROOT_ID" "
\$ErrorActionPreference='Stop'
\$b64 = '$(cat /tmp/pki-sub.csr.b64)'
[IO.File]::WriteAllBytes('C:\\sub.req', [Convert]::FromBase64String(\$b64))
Remove-Item 'C:\\sub.cer','C:\\sub.rsp' -ErrorAction SilentlyContinue
# SubCA template: the issued cert must itself be a CA (basicConstraints CA:TRUE)
\$out = certreq -config - -submit -attrib 'CertificateTemplate:SubCA' 'C:\\sub.req' 'C:\\sub.cer' 2>&1 | Out-String
if (-not (Test-Path 'C:\\sub.cer')) {
  # A standalone CA holds requests pending by default; approve and retrieve.
  \$id = (certutil -view -restrict 'Disposition=9' -out RequestID | Select-String 'Row ' -Context 0,3 |
         Out-String | Select-String -Pattern 'Request ID: *\"?(\\d+)' -AllMatches).Matches |
         ForEach-Object { \$_.Groups[1].Value } | Select-Object -Last 1
  if (\$id) { certutil -resubmit \$id | Out-Null; certreq -retrieve \$id 'C:\\sub.cer' | Out-Null }
}
if (-not (Test-Path 'C:\\sub.cer')) { Write-Error \"signing failed: \$out\"; exit 1 }
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\\sub.cer'))
" "root-sign" 600 | tr -d '\r\n ' > /tmp/pki-sub.cer.b64
say "issuing CA certificate signed"

# also grab the root certificate itself — needed for the AD trust publication
run_ps "$ROOT_ID" "
\$c = Get-ChildItem Cert:\\LocalMachine\\CA,Cert:\\LocalMachine\\Root |
      Where-Object { \$_.Subject -like '*${CA_ROOT_CN:-PANW Lab Root CA}*' } | Select-Object -First 1
if (-not \$c) { Write-Error 'root cert not found'; exit 1 }
[Convert]::ToBase64String(\$c.RawData)
" "root-cert" 300 | tr -d '\r\n ' > /tmp/pki-root.cer.b64

# --- 4. issuing CA: install the signed certificate ---------------------------
say "installing the signed certificate on the issuing CA"
run_ps "$SUB_ID" "
\$ErrorActionPreference='Stop'
[IO.File]::WriteAllBytes('C:\\root.cer', [Convert]::FromBase64String('$(cat /tmp/pki-root.cer.b64)'))
[IO.File]::WriteAllBytes('C:\\sub.cer',  [Convert]::FromBase64String('$(cat /tmp/pki-sub.cer.b64)'))
# The root must be trusted locally before its child will install.
certutil -addstore -f Root 'C:\\root.cer' | Out-Null
certutil -installcert 'C:\\sub.cer'       | Out-Null
Start-Service certsvc
(Get-Service certsvc).Status
" "sub-install" 600
say "issuing CA service started"

# --- 5. publish the ROOT into AD so domain members trust it automatically ----
# This is what makes the client side hands-off: -dspublish writes the root into
# the forest's Certification Authorities container, and every domain-joined
# machine pulls it into its Trusted Root store on the next policy refresh.
say "publishing the root CA into Active Directory"
run_ps "$SUB_ID" "
\$ErrorActionPreference='Stop'
certutil -dspublish -f 'C:\\root.cer' RootCA | Out-Null
certutil -dspublish -f 'C:\\root.cer' NTAuthCA | Out-Null
gpupdate /force | Out-Null
'published'
" "ad-publish" 600

# --- 6. take the root offline ------------------------------------------------
say "stopping the root CA — its job is done until the issuing CA needs renewal"
aws ec2 stop-instances --region "$REGION" --instance-ids "$ROOT_ID" \
  --query 'StoppingInstances[0].CurrentState.Name' --output text

say "two-tier PKI ready. Root is offline; issuing CA is live and published to AD."
