#!/usr/bin/env bash
###############################################################################
# guacamole-ldap-setup.sh — the AD side of the Guacamole AD sign-in (root guac_ldap_enabled).
#
# Creates, on the domain controller through SSM RunCommand (as SYSTEM, so no domain admin
# password is needed):
#   * the group whose members may sign in (default guacusers), plus the given members;
#   * the bind account Guacamole uses to look users up (default svc-guacamole: a plain domain
#     user, no extra rights), with the password Terraform generated into the Guacamole secret.
#     An existing account gets its password reset to that value, so re-running after the host
#     (and with it the generated password) was replaced is the fix for "invalid credentials".
#
# The password travels in the RunCommand parameters (kept in the SSM command history), as in
# create-ad-test-user.sh. Members are matched by sAMAccountName.
#
# Required env (values never committed):
#   AWS_REGION        deploy region
#   DC_INSTANCE_ID    root output dc_instance_id
#   GUAC_SECRET_ARN   root output guacamole_admin_secret_arn
# Optional:
#   GUAC_USERS        space-separated sAMAccountNames to add to the group
#   GUAC_GROUP        default guacusers      (must match root guac_ldap_group)
#   GUAC_BIND_USER    default svc-guacamole  (must match the module's ldap_bind_user)
#   DOMAIN            default panw.labs
#
# Usage: guacamole-ldap-setup.sh
###############################################################################
set -euo pipefail
REGION="${AWS_REGION:?AWS_REGION required}"
: "${DC_INSTANCE_ID:?DC_INSTANCE_ID required}" "${GUAC_SECRET_ARN:?GUAC_SECRET_ARN required}"
GROUP="${GUAC_GROUP:-guacusers}"
BIND_USER="${GUAC_BIND_USER:-svc-guacamole}"
DOMAIN="${DOMAIN:-panw.labs}"
say() { echo "[guac-ldap] $*"; }
die() { echo "[guac-ldap] ERROR: $*" >&2; exit 1; }

members=""
for u in "$GROUP" "$BIND_USER" ${GUAC_USERS:-}; do
  [[ "$u" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "invalid name: $u"
done
for u in ${GUAC_USERS:-}; do members="${members}'${u}',"; done
members="${members%,}"

pw="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$GUAC_SECRET_ARN" \
      --query SecretString --output text | jq -r '.ldap_bind_password // empty')"
[ -n "$pw" ] || die "no ldap_bind_password in the secret: apply root with guac_ldap_enabled = true first"
# random_password with special = false: letters and digits only, safe inside a '...' string.
[[ "$pw" =~ ^[A-Za-z0-9]+$ ]] || die "unexpected characters in the bind password"

ps="\$ErrorActionPreference='Stop'
if (-not (Get-ADGroup -Filter \"Name -eq '${GROUP}'\")) { New-ADGroup -Name '${GROUP}' -SamAccountName '${GROUP}' -GroupScope Global -GroupCategory Security; 'group ${GROUP} created' }
\$pw = ConvertTo-SecureString '${pw}' -AsPlainText -Force
if (Get-ADUser -Filter \"SamAccountName -eq '${BIND_USER}'\") { Set-ADAccountPassword -Identity '${BIND_USER}' -Reset -NewPassword \$pw; Enable-ADAccount '${BIND_USER}'; '${BIND_USER} password reset' }
else { New-ADUser -Name '${BIND_USER}' -SamAccountName '${BIND_USER}' -UserPrincipalName '${BIND_USER}@${DOMAIN}' -AccountPassword \$pw -Enabled \$true -PasswordNeverExpires \$true -CannotChangePassword \$true -Description 'Guacamole LDAP bind (read-only)'; '${BIND_USER} created' }
foreach (\$u in @(${members})) { Add-ADGroupMember -Identity '${GROUP}' -Members \$u }
'bind DN: ' + (Get-ADUser '${BIND_USER}').DistinguishedName
'group DN: ' + (Get-ADGroup '${GROUP}').DistinguishedName
'${GROUP}: ' + ((Get-ADGroupMember '${GROUP}' | ForEach-Object SamAccountName) -join ',')"
unset pw

pfile="$(mktemp)"
trap 'rm -f "$pfile"' EXIT
printf '%s' "$ps" | jq -R -s '{commands: (rtrimstr("\n") | split("\n"))}' > "$pfile"
unset ps
cid="$(aws ssm send-command --region "$REGION" --instance-ids "$DC_INSTANCE_ID" \
      --document-name AWS-RunPowerShellScript --parameters "file://${pfile}" \
      --query 'Command.CommandId' --output text)" || die "send-command failed"
rm -f "$pfile"
for _ in $(seq 1 60); do
  status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
            --instance-id "$DC_INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$status" in Success|Failed|TimedOut|Cancelled) break ;; esac
  sleep 5
done
aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$DC_INSTANCE_ID" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
[ "$status" = "Success" ] || die "the AD step ended as $status"
say "group ${GROUP} and bind account ${BIND_USER} ready; the DN must match CN=Users (the module assumes it)"
