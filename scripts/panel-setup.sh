#!/usr/bin/env bash
###############################################################################
# panel-setup.sh — the two one-off steps the admin panel needs after `terraform apply`.
#
#   ad   create the AD group the panel requires (default `panel-admins`) and add the
#        given users to it. Runs on the domain controller through SSM RunCommand.
#   fw   create the restricted firewall admin the panel uses (custom role panel-ro: op commands only,
#        no config access/commit; password taken
#        from the panel's Secrets Manager secret) on each firewall, then commit.
#        Uses the XML API through the SSM jump host.
#
# Required env (values never committed):
#   AWS_REGION            deploy region
#   ad:  DC_INSTANCE_ID   (root output dc_instance_id)
#        DOMAIN_ADMIN_USER / DOMAIN_ADMIN_PASSWORD   (AD admin; used for the scheduled task)
#        PANEL_USERS      space-separated sAMAccountNames to add to the group
#        optional PANEL_GROUP (default panel-admins), DOMAIN (default panw.labs)
#   fw:  JUMP_INSTANCE_ID  (root output ssm_jumphost_instance_id)
#        PANEL_SECRET_ARN  (root output panel_secret_arn)
#        FW_IPS            space-separated firewall mgmt IPs
#        FW_ADMIN_USER / FW_ADMIN_PASSWORD   an existing superuser on the firewalls
#
# Usage: panel-setup.sh <ad|fw>
###############################################################################
set -euo pipefail
MODE="${1:?usage: $0 <ad|fw>}"
REGION="${AWS_REGION:?AWS_REGION required}"
say() { echo "[panel] $*"; }
die() { echo "[panel] ERROR: $*" >&2; pkill -f 'session-manager-plugin.*22443' 2>/dev/null || true; exit 1; }

ad_step() {
  : "${DC_INSTANCE_ID:?}" "${DOMAIN_ADMIN_USER:?}" "${DOMAIN_ADMIN_PASSWORD:?}" "${PANEL_USERS:?}"
  local group="${PANEL_GROUP:-panel-admins}" domain="${DOMAIN:-panw.labs}" users="" u
  for u in $PANEL_USERS; do
    [[ "$u" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "invalid user name: $u"
    users="${users}'${u}',"
  done
  users="${users%,}"
  local ps pfile cid status
  ps="\$ErrorActionPreference='Stop'
if (-not (Get-ADGroup -Filter \"Name -eq '${group}'\")) { New-ADGroup -Name '${group}' -GroupScope Global -GroupCategory Security }
foreach (\$u in @(${users})) { Add-ADGroupMember -Identity '${group}' -Members \$u }
'members: ' + ((Get-ADGroupMember '${group}' | ForEach-Object SamAccountName) -join ',')"
  pfile="$(mktemp)"
  printf '%s' "$ps" | jq -R -s '{commands: (rtrimstr("\n") | split("\n"))}' > "$pfile"
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
  [ "$status" = "Success" ] || die "the group step ended as $status"
  say "group ${group} ready on the domain controller"
}

fw_api() {  # $1 = local port; rest = curl --data-urlencode args
  local port="$1"; shift
  curl -sk --max-time 40 "https://127.0.0.1:${port}/api/" "$@"
}

fw_step() {
  : "${JUMP_INSTANCE_ID:?}" "${PANEL_SECRET_ARN:?}" "${FW_IPS:?}" "${FW_ADMIN_USER:?}" "${FW_ADMIN_PASSWORD:?}"
  local sec user pw lp=22443 ip key hash job res
  sec="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$PANEL_SECRET_ARN" --query SecretString --output text)"
  user="$(jq -r .fw_user <<<"$sec")"; pw="$(jq -r .fw_password <<<"$sec")"
  for ip in $FW_IPS; do
    say "firewall $ip"
    if nc -z -G 2 127.0.0.1 "$lp" >/dev/null 2>&1; then die "local port $lp already in use (stale SSM tunnel?)"; fi
    aws ssm start-session --target "$JUMP_INSTANCE_ID" --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters "{\"host\":[\"$ip\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"$lp\"]}" >/dev/null 2>&1 &
    local pid=$!
    for _ in $(seq 1 20); do nc -z -G 2 127.0.0.1 "$lp" >/dev/null 2>&1 && break; sleep 1; done
    # shellcheck disable=SC2064
    trap "kill $pid 2>/dev/null || true; pkill -f 'session-manager-plugin.*$lp' 2>/dev/null || true" RETURN
    res="$(fw_api "$lp" --data-urlencode type=keygen --data-urlencode "user=$FW_ADMIN_USER" \
          --data-urlencode "password=$FW_ADMIN_PASSWORD" || true)"
    key="$(sed -nE 's/.*<key>([^<]+)<\/key>.*/\1/p' <<<"$res")"
    [ -n "$key" ] || die "no API key from $ip as $FW_ADMIN_USER. Answer: $(tr -d '\n' <<<"$res" | cut -c1-300)"
    hash="$(fw_api "$lp" --data-urlencode type=op --data-urlencode "key=$key" \
          --data-urlencode "cmd=<request><password-hash><password>${pw}</password></password-hash></request>" \
          | sed -E 's/.*<phash>([^<]+)<\/phash>.*/\1/')"
    [ -n "$hash" ] && [[ "$hash" != *"<"* ]] || die "password hash request failed on $ip"
    # Role: XML-API operational commands ON (status, `test security-policy-match`, list
    # samples) but configuration reads/writes, commit, export and import OFF. `superreader`
    # is not enough: it cannot run those op commands through the XML API.
    res="$(fw_api "$lp" --data-urlencode type=config --data-urlencode action=set --data-urlencode "key=$key" \
          --data-urlencode "xpath=/config/shared/admin-role/entry[@name='panel-ro']" \
          --data-urlencode "element=<role><device><cli>superreader</cli><webui><dashboard>disable</dashboard></webui><xmlapi><report>disable</report><log>disable</log><config>disable</config><op>enable</op><commit>disable</commit><export>disable</export><import>disable</import></xmlapi><restapi><device><objects>disable</objects></device></restapi></device></role>")"
    grep -q 'status="success"' <<<"$res" || die "creating the panel-ro role on $ip failed: $res"
    # Re-create the user from scratch so a previous superreader assignment cannot linger.
    fw_api "$lp" --data-urlencode type=config --data-urlencode action=delete --data-urlencode "key=$key" \
          --data-urlencode "xpath=/config/mgt-config/users/entry[@name='${user}']" >/dev/null || true
    res="$(fw_api "$lp" --data-urlencode type=config --data-urlencode action=set --data-urlencode "key=$key" \
          --data-urlencode "xpath=/config/mgt-config/users/entry[@name='${user}']" \
          --data-urlencode "element=<phash>${hash}</phash><permissions><role-based><custom><profile>panel-ro</profile></custom></role-based></permissions>")"
    grep -q 'status="success"' <<<"$res" || die "creating $user on $ip failed: $res"
    job="$(fw_api "$lp" --data-urlencode type=commit --data-urlencode "key=$key" --data-urlencode "cmd=<commit></commit>" \
          | sed -nE 's/.*<job>([0-9]+)<\/job>.*/\1/p')"
    if [ -n "$job" ]; then
      for _ in $(seq 1 60); do
        res="$(fw_api "$lp" --data-urlencode type=op --data-urlencode "key=$key" --data-urlencode "cmd=<show><jobs><id>${job}</id></jobs></show>")"
        grep -q '<status>FIN</status>' <<<"$res" && break
        sleep 5
      done
      grep -q '<result>OK</result>' <<<"$res" || die "commit on $ip did not finish OK"
    fi
    say "$user (read-only) ready on $ip"
    kill "$pid" 2>/dev/null || true; pkill -f "session-manager-plugin.*$lp" 2>/dev/null || true
    trap - RETURN
    sleep 2
  done
}

case "$MODE" in ad) ad_step ;; fw) fw_step ;; *) die "usage: $0 <ad|fw>" ;; esac
