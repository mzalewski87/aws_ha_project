#!/usr/bin/env bash
###############################################################################
# gp-ldap-setup.sh — the AD side of the GlobalProtect AD sign-in in path B
# (scm-gp-local.sh with GP_AUTH=ldap).
#
# Creates, on the domain controller through SSM RunCommand (as SYSTEM, so no domain admin
# password is needed):
#   * the group whose members may connect (default vpnusers; root gp_vpn_group). The primary DC
#     normally has it already (create-ad-test-user.sh), so this is a no-op then;
#   * the bind account the firewalls use to look users and the group up (default svc-gp-ldap: a
#     plain domain user, no extra rights). An existing account gets its password reset, so a
#     re-run is also the fix for a firewall bind error after the password changed;
#   * optionally an AD test user (default gpuser) in the group, with GP_USER_PASSWORD;
#   * the given extra members of the group.
#
# Passwords travel in the RunCommand parameters (kept in the SSM command history), as in
# create-ad-test-user.sh and guacamole-ldap-setup.sh. Letters and digits only, so they are
# safe inside a PowerShell '...' string; AD's complexity rule needs upper case, lower case and
# digits. Members are matched by sAMAccountName.
#
# Required env (values never committed):
#   AWS_REGION              deploy region
#   DC_INSTANCE_ID          root output dc_instance_id (the primary DC; AD replicates the rest)
#   GP_LDAP_BIND_PASSWORD   the bind account's password (the same value goes to scm-gp-local.sh)
# Optional:
#   GP_VPN_GROUP     default vpnusers     (must match scm-gp-local.sh GP_VPN_GROUP)
#   LDAP_BIND_USER   default svc-gp-ldap  (must match scm-gp-local.sh LDAP_BIND_USER)
#   GP_TEST_USER     default gpuser; set GP_TEST_USER="" to skip it
#   GP_USER_PASSWORD the test user's password (required when GP_TEST_USER is set)
#   GP_USERS         space-separated sAMAccountNames to add to the group (e.g. "admin")
#   DOMAIN           default panw.labs
#
# Usage: gp-ldap-setup.sh
###############################################################################
set -euo pipefail

REGION="${AWS_REGION:?AWS_REGION required}"
: "${DC_INSTANCE_ID:?DC_INSTANCE_ID required}" "${GP_LDAP_BIND_PASSWORD:?GP_LDAP_BIND_PASSWORD required}"
GROUP="${GP_VPN_GROUP:-vpnusers}"
BIND_USER="${LDAP_BIND_USER:-svc-gp-ldap}"
TEST_USER="${GP_TEST_USER-gpuser}"
DOMAIN="${DOMAIN:-panw.labs}"

say() { echo "[gp-ldap] $*"; }
die() { echo "[gp-ldap] ERROR: $*" >&2; exit 1; }

for u in "$GROUP" "$BIND_USER" $TEST_USER ${GP_USERS:-}; do
  [[ "$u" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "invalid name: $u"
done
pw_ok() { [[ "$1" =~ ^[A-Za-z0-9]{12,}$ && "$1" =~ [A-Z] && "$1" =~ [a-z] && "$1" =~ [0-9] ]]; }
pw_ok "$GP_LDAP_BIND_PASSWORD" || die "GP_LDAP_BIND_PASSWORD: 12+ letters and digits, with upper case, lower case and a digit"
if [ -n "$TEST_USER" ]; then
  : "${GP_USER_PASSWORD:?GP_USER_PASSWORD required for the test user $TEST_USER (or set GP_TEST_USER=\"\")}"
  pw_ok "$GP_USER_PASSWORD" || die "GP_USER_PASSWORD: 12+ letters and digits, with upper case, lower case and a digit (AD complexity)"
fi

members=""
for u in $TEST_USER ${GP_USERS:-}; do members="${members}'${u}',"; done
members="${members%,}"

# ensure_user NAME PASSWORD DESCRIPTION -> PowerShell: create, or reset the password of, a user.
ensure_user() {
  printf '%s\n' "\$pw = ConvertTo-SecureString '$2' -AsPlainText -Force
if (Get-ADUser -Filter \"SamAccountName -eq '$1'\") { Set-ADAccountPassword -Identity '$1' -Reset -NewPassword \$pw; Enable-ADAccount '$1'; '$1 password reset' }
else { New-ADUser -Name '$1' -SamAccountName '$1' -UserPrincipalName '$1@${DOMAIN}' -AccountPassword \$pw -Enabled \$true -PasswordNeverExpires \$true -Description '$3'; '$1 created' }"
}

ps="\$ErrorActionPreference='Stop'
if (-not (Get-ADGroup -Filter \"Name -eq '${GROUP}'\")) { New-ADGroup -Name '${GROUP}' -SamAccountName '${GROUP}' -GroupScope Global -GroupCategory Security; 'group ${GROUP} created' }
$(ensure_user "$BIND_USER" "$GP_LDAP_BIND_PASSWORD" 'GlobalProtect LDAP bind (read-only)')
Set-ADUser -Identity '${BIND_USER}' -CannotChangePassword \$true"
[ -n "$TEST_USER" ] && ps="$ps
$(ensure_user "$TEST_USER" "$GP_USER_PASSWORD" 'GlobalProtect test user')"
ps="$ps
foreach (\$u in @(${members})) { Add-ADGroupMember -Identity '${GROUP}' -Members \$u }
'bind DN: ' + (Get-ADUser '${BIND_USER}').DistinguishedName
'group DN: ' + (Get-ADGroup '${GROUP}').DistinguishedName
'${GROUP}: ' + ((Get-ADGroupMember '${GROUP}' | ForEach-Object SamAccountName) -join ',')"

pfile="$(mktemp)"
trap 'rm -f "$pfile"' EXIT
printf '%s' "$ps" | jq -R -s '{commands: (rtrimstr("\n") | split("\n"))}' > "$pfile"
unset ps
cid="$(aws ssm send-command --region "$REGION" --instance-ids "$DC_INSTANCE_ID" \
      --document-name AWS-RunPowerShellScript --parameters "file://${pfile}" \
      --query 'Command.CommandId' --output text)" || die "send-command failed"
rm -f "$pfile"

status=Pending
for _ in $(seq 1 60); do
  status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
            --instance-id "$DC_INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$status" in Success|Failed|TimedOut|Cancelled) break ;; esac
  sleep 5
done
aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$DC_INSTANCE_ID" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
[ "$status" = "Success" ] || die "the AD step ended as $status"
say "group ${GROUP}, bind account ${BIND_USER}${TEST_USER:+ and test user ${TEST_USER}} ready (DNs under CN=Users, as scm-gp-local.sh assumes)"
