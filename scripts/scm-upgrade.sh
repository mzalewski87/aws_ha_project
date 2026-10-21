#!/usr/bin/env bash
###############################################################################
# scm-upgrade.sh — upgrade the PAN-OS of the firewalls in an SCM folder, with HA
# orchestration, and wait for the result.
#
# SCM schedules software upgrades through two objects (device-settings API):
#   * a RULE      — which devices (match_criteria: folders / models / excluded serials)
#   * a SCHEDULE  — which image, download vs install, start time, `ha_orchestration`
# ha_orchestration = true is sent, but live (12.2.3 -> 12.2.4) both units rebooted within a few
# seconds of each other, so plan the upgrade as a short outage, not a rolling one.
# /software-upgrade-status stayed empty during a successful upgrade; completion is judged by
# what the devices report (target version, connected, every pair active/passive).
#
# WHY A SCRIPT: the `scm` Terraform provider has no resource for upgrades.
#
# Usage: scm-upgrade.sh <folder> <version> [start_in_minutes=3]
#   e.g. scm-upgrade.sh AWS-HA-Transit 12.2.4
#
# Learned live (the OpenAPI document is wrong or silent on these): ids come back in the `id`
# field, dates are YYYY/MM/DD, start times are read as UTC, job_type must be
# download-install-reboot. Changing the version recreates nothing: it is an in-place upgrade with a reboot of each
# firewall, so GlobalProtect and the inspected path see a short interruption on failover.
###############################################################################
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scm-lib.sh
source "$HERE/scm-lib.sh"

FOLDER="${1:?usage: $0 <folder> <version> [start_in_minutes]}"
VERSION="${2:?usage: $0 <folder> <version> [start_in_minutes]}"
IN_MIN="${3:-3}"
[[ "$IN_MIN" =~ ^[0-9]+$ ]] || scm_die "start_in_minutes must be a number"
BASE="/config/device/v1"
NAME="upgrade-${FOLDER}-${VERSION//./-}"

# The version must be one SCM knows (and that the firmware is actually published for).
scm_api GET "$BASE/software-versions" | jq -e --arg v "$VERSION" '.versions | index($v) != null' >/dev/null \
  || scm_die "SCM does not list PAN-OS $VERSION in /software-versions"

# Refuse to start unless every firewall of the folder is connected: an HA upgrade that begins
# with one unit down turns a rolling upgrade into an outage.
unhealthy="$(scm_api GET "/config/setup/v1/devices?limit=500" | jq -r --arg f "$FOLDER" \
  '[(.data // [])[] | select(.folder == $f and .is_connected != true) | .name] | join(",")')"
[ -z "$unhealthy" ] || scm_die "devices in '$FOLDER' are not connected: $unhealthy — fix that before upgrading"
scm_api GET "/config/setup/v1/devices?limit=500" | jq -r --arg f "$FOLDER" \
  '(.data // [])[] | select(.folder == $f) | "  \(.name)  sw=\(.software_version)  ha=\(.ha_state)"' >&2

# Devices of the folder that already run the target version are EXCLUDED (match_criteria
# field `exclude_devices`, a list of serials — found by probing: it is the field the API stores;
# `devices.exclude` and `serial_numbers.exclude` are accepted but silently dropped). Without it,
# upgrading a second region's pair would also hit the pair that is already up to date.
devs_all="$(scm_api GET "/config/setup/v1/devices?limit=500")"
excl="$(jq -c --arg f "$FOLDER" --arg v "$VERSION" '[(.data // [])[] | select(.folder == $f)
         | select(.software_version as $s | $s == $v or ($s | startswith($v + "-"))) | .name]' <<<"$devs_all")"
todo="$(jq -r --arg f "$FOLDER" --arg v "$VERSION" '[(.data // [])[] | select(.folder == $f)
         | select((.software_version as $s | $s == $v or ($s | startswith($v + "-"))) | not) | .name] | join(",")' <<<"$devs_all")"
[ -n "$todo" ] || { scm_log "every firewall in '$FOLDER' already runs $VERSION — nothing to do"; exit 0; }
scm_log "to upgrade: $todo; excluded (already on $VERSION): $(jq -r 'join(",")' <<<"$excl")"
rule="$(jq -nc --arg n "$NAME" --arg f "$FOLDER" --argjson x "$excl" \
  '{name:$n, description:"managed by scm-upgrade.sh", enabled:true,
    match_criteria:({ folders:{include:[$f]} } + (if ($x | length) > 0 then {exclude_devices:$x} else {} end))}')"
# Reuse (and update) an existing rule of the same name instead of failing on a re-run.
rule_id="$(scm_api GET "$BASE/software-upgrade-rules?name=$(scm_urlenc "$NAME")" \
  | jq -r --arg n "$NAME" '(if type=="array" then . else (.data // []) end) | map(select(.name == $n)) | first | .id // empty')"
if [ -z "$rule_id" ]; then
  scm_api POST "$BASE/software-upgrade-rules" "$rule" >/dev/null
  scm_log "created upgrade rule $NAME"
else
  scm_api PUT "$BASE/software-upgrade-rules/$rule_id" "$rule" >/dev/null \
    || scm_die "could not update upgrade rule $NAME ($rule_id)"
  stored="$(scm_api GET "$BASE/software-upgrade-rules?name=$(scm_urlenc "$NAME")" \
    | jq -c --arg n "$NAME" '(if type=="array" then . else (.data // []) end) | map(select(.name == $n)) | first | .match_criteria')"
  [ "$(jq -c '.exclude_devices // []' <<<"$stored")" = "$excl" ] \
    || scm_die "rule $NAME did not keep the exclusion list (stored: $stored) — refusing to upgrade units that are already on $VERSION"
  scm_log "updated upgrade rule $NAME: $stored"
fi

# What the live API actually wants (found by probing with disabled schedules; the OpenAPI is
# wrong on these points):
#   * dates are YYYY/MM/DD (slashes). YYYY-MM-DD is rejected as "invalid date" for ANY value,
#     which looked like a time-zone or "in the past" problem and was neither;
#   * job_type "install" is "not an allowed keyword". The tenant's own schedules use
#     "download-install-reboot", which is the full upgrade. Omitting job_type is ACCEPTED but did
#     nothing at the start time, so always send it;
#   * a schedule with no times at all is refused ("install and download time missing");
#   * start-time is read as UTC: a time that was still ahead in UTC but already past in Warsaw
#     was accepted. (An earlier version sent Warsaw time, which the server read as UTC two hours
#     later, so the schedule silently waited instead of starting.)
TZN="${SCM_TZ:-UTC}"
INSTALL_GAP="${INSTALL_GAP_MIN:-15}"   # minutes between the image download and the install
at_plus() { # $1 = minutes from now -> "YYYY/MM/DD HH:MM" in $TZN (macOS and GNU date)
  if TZ="$TZN" date -v+"$1"M +%Y >/dev/null 2>&1; then TZ="$TZN" date -v+"$1"M '+%Y/%m/%d %H:%M'
  else TZ="$TZN" date -d "+$1 minutes" '+%Y/%m/%d %H:%M'; fi
}
read -r DL_DATE DL_AT <<<"$(at_plus "$IN_MIN")"
read -r IN_DATE IN_AT <<<"$(at_plus $(( IN_MIN + INSTALL_GAP )))"
sched="$(jq -nc --arg n "$NAME" --arg v "$VERSION" --arg dd "$DL_DATE" --arg dt "$DL_AT" --arg id "$IN_DATE" --arg it "$IN_AT" \
  '{name:$n, description:"managed by scm-upgrade.sh", enabled:true, job_type:"download-install-reboot",
    allow_downgrade:false, ha_orchestration:true, image_version:$v,
    download_starttime:{date:$dd, at:$dt}, install_starttime:{date:$id, at:$it},
    rules:[$n]}')"
resp="$(scm_api POST "$BASE/software-upgrade-schedules" "$sched")" \
  || scm_die "could not create the upgrade schedule (see the API error above)"
sid="$(jq -r '.id // empty' <<<"$resp")"
[ -n "$sid" ] || scm_die "schedule created but no id in the response: $resp"
scm_log "schedule $sid: PAN-OS $VERSION on '$FOLDER', HA orchestrated; download $DL_DATE $DL_AT, install $IN_DATE $IN_AT ($TZN)"
# Whatever happens next (success, timeout, error), never leave an enabled schedule behind: its
# start time is in the past, and a re-run would fail on the duplicate name.
trap 'scm_api DELETE "$BASE/software-upgrade-schedules/$sid" >/dev/null 2>&1 && scm_log "schedule $sid removed"' EXIT

# Wait for the result. GET /software-upgrade-status stayed an EMPTY LIST for the whole of a
# real, successful upgrade on this tenant, so it cannot be the completion signal. What the
# devices themselves report is: done = every firewall of the folder runs the target version,
# is connected again, and the HA pair is healthy (one active + one passive). The status
# endpoint is still read and printed when it does return something.
deadline=$(( $(date +%s) + ${UPGRADE_TIMEOUT:-5400} ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  st="$(scm_api GET "$BASE/software-upgrade-status" 2>/dev/null || true)"
  one="$(jq -c --arg s "$sid" '(if type=="array" then . else (.data // [.]) end) | map(select(.schedule_id == $s)) | first // empty' <<<"$st" 2>/dev/null || true)"
  if [ -n "$one" ]; then
    jq -r '.devices[]? | "    \(.device_serial_no): " + ([.status.status_details // {} | to_entries[] | select(.value.state != null and .value.state != "") | "\(.key)=\(.value.state)"] | join(" "))' <<<"$one" >&2
    [ "$(jq -r '.overall_status // ""' <<<"$one")" = "failed" ] && scm_die "the upgrade FAILED — inspect: GET $BASE/software-upgrade-status"
  fi
  devs="$(scm_api GET "/config/setup/v1/devices?limit=500" 2>/dev/null || true)"
  summary="$(jq -r --arg f "$FOLDER" '[(.data // [])[] | select(.folder == $f) | "\(.name):\(.software_version):\(if .is_connected then "up" else "DOWN" end):\(.ha_state)"] | join("  ")' <<<"$devs" 2>/dev/null || true)"
  scm_log "devices: ${summary:-<no answer — a unit is probably rebooting>}"
  ok="$(jq -r --arg f "$FOLDER" --arg v "$VERSION" '
      [(.data // [])[] | select(.folder == $f)] as $d
      | ($d | length) > 0
        and ($d | all(.software_version as $s | $s == $v or ($s | startswith($v + "-"))))
        and ($d | all(.is_connected == true))
        and ($d | all(.ha_state == "active" or .ha_state == "passive"))
        and (($d | map(select(.ha_state == "active")) | length) == ($d | map(select(.ha_state == "passive")) | length))' <<<"$devs" 2>/dev/null || echo false)"
  if [ "$ok" = "true" ]; then
    scm_log "upgrade finished: every firewall runs $VERSION, is connected and every pair is active/passive"
    exit 0   # the EXIT trap removes the schedule
  fi
  sleep 60
done
scm_die "upgrade did not finish within ${UPGRADE_TIMEOUT:-5400}s (devices: ${summary:-unknown})"
