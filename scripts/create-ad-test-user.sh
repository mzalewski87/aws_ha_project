#!/usr/bin/env bash
###############################################################################
# create-ad-test-user.sh — invoked by Terraform (terraform_data local-exec).
#
# WHY: dc_promote_to_dc runs Install-ADDSForest once, in user-data, at first
# boot — it can't also safely create AD objects there (the forest doesn't
# exist yet when user-data runs, and Install-ADDSForest's own reboot would
# interrupt anything queued after it). This creates a single AD test user
# ("admin" by default) AFTER the forest is confirmed up, via SSM RunCommand —
# the DC has its own SSM agent + IAM role (see modules/spoke2_dc), so this
# needs no Bastion/jump-host relay, no FW policy change, no TGW route change.
#
# Idempotent: the PowerShell payload checks for the user before creating it,
# and waits (inside the SAME RunCommand invocation, via -ExecutionTimeout) for
# the AD DS role to actually be ready — Install-ADDSForest's reboot can take
# several minutes, and the SSM agent itself has to survive/reconnect through it.
#
# Inputs (env, so the secret never lands in argv / process list):
#   AWS_REGION, DC_INSTANCE_ID, AD_USERNAME (default admin), AD_USER_PASSWORD,
#   AD_DOMAIN
###############################################################################
set -euo pipefail

: "${DC_INSTANCE_ID:?DC_INSTANCE_ID required}"
: "${AD_USER_PASSWORD:?AD_USER_PASSWORD required}"
: "${AD_DOMAIN:?AD_DOMAIN required}"
AD_USERNAME="${AD_USERNAME:-admin}"
export AWS_REGION="${AWS_REGION:-eu-central-1}"

echo "[ad-user] waiting for SSM agent on ${DC_INSTANCE_ID} (up to 20 min; survives the AD DS promotion reboot)"
ready=0
for _ in $(seq 1 120); do
  status="$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${DC_INSTANCE_ID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
  if [ "${status}" = "Online" ]; then ready=1; break; fi
  sleep 10
done
if [ "${ready}" -ne 1 ]; then
  echo "[ad-user] ERROR: SSM agent on ${DC_INSTANCE_ID} never came Online" >&2
  exit 1
fi

# The RunCommand payload itself waits (up to 15 min, --execution-timeout below
# gives headroom) for `Get-ADDomain` to succeed before creating the user, since
# AD DS can take a few more minutes to accept requests after the SSM agent
# reconnects post-reboot.
PS_SCRIPT="$(python3 - "$AD_USERNAME" "$AD_USER_PASSWORD" "$AD_DOMAIN" <<'PY'
import sys, json
user, pw, domain = sys.argv[1], sys.argv[2], sys.argv[3]
pw_escaped = pw.replace("'", "''")
script = f"""
$deadline = (Get-Date).AddMinutes(15)
$adReady = $false
while ((Get-Date) -lt $deadline) {{
  try {{
    Import-Module ActiveDirectory -ErrorAction Stop
    $null = Get-ADDomain -ErrorAction Stop
    $adReady = $true
    break
  }} catch {{
    Start-Sleep -Seconds 15
  }}
}}
if (-not $adReady) {{
  Write-Output "AD DS not ready after wait"
  exit 1
}}
if (Get-ADUser -Filter "SamAccountName -eq '{user}'" -ErrorAction SilentlyContinue) {{
  Write-Output "user '{user}' already exists"
}} else {{
  $securePwd = ConvertTo-SecureString '{pw_escaped}' -AsPlainText -Force
  New-ADUser -Name '{user}' -SamAccountName '{user}' -UserPrincipalName '{user}@{domain}' `
    -AccountPassword $securePwd -Enabled $true -PasswordNeverExpires $true -ChangePasswordAtLogon $false
  Write-Output "user '{user}' created"
}}
# Ensure the account is a Domain Admin. It doubles as the GP LDAP bind account
# AND as the credential used to promote the Region-B additional DC
# (Install-ADDSDomainController needs Domain/Enterprise Admin rights). Lab
# convenience — not a production pattern. Idempotent.
try {{
  Add-ADGroupMember -Identity 'Domain Admins' -Members '{user}' -ErrorAction Stop
  Write-Output "user '{user}' added to Domain Admins"
}} catch {{
  Write-Output "Domain Admins membership: $($_.Exception.Message)"
}}
"""
print(json.dumps([line for line in script.splitlines()]))
PY
)"

echo "[ad-user] sending SSM RunCommand"
CMD_ID="$(aws ssm send-command \
  --instance-ids "${DC_INSTANCE_ID}" \
  --document-name "AWS-RunPowerShellScript" \
  --timeout-seconds 1200 \
  --parameters "{\"commands\":${PS_SCRIPT},\"executionTimeout\":[\"1200\"]}" \
  --query 'Command.CommandId' --output text)"
echo "[ad-user] command id: ${CMD_ID}"

for _ in $(seq 1 90); do
  st="$(aws ssm get-command-invocation --command-id "${CMD_ID}" --instance-id "${DC_INSTANCE_ID}" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")"
  [ "${st}" = "InProgress" ] || [ "${st}" = "Pending" ] || break
  sleep 10
done

RESULT="$(aws ssm get-command-invocation --command-id "${CMD_ID}" --instance-id "${DC_INSTANCE_ID}" \
  --query '{Status:Status,Out:StandardOutputContent,Err:StandardErrorContent}' --output json)"
echo "[ad-user] result: ${RESULT}"
echo "${RESULT}" | grep -q '"Status": "Success"' || { echo "[ad-user] ERROR: RunCommand did not succeed" >&2; exit 1; }
echo "[ad-user] done"
