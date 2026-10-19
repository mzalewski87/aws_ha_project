#!/usr/bin/env bash
###############################################################################
# scm-upgrade.sh — upgrade the PAN-OS of the firewalls in an SCM folder, with HA
# orchestration, and wait for the result.
#
# SCM schedules software upgrades through two objects (device-settings API):
#   * a RULE      — which devices (match_criteria: folders / models / excluded serials)
#   * a SCHEDULE  — which image, download vs install, start time, `ha_orchestration`
# With ha_orchestration = true SCM sequences the pair itself (passive first) instead of
# taking both firewalls down at once. Progress is read from /software-upgrade-status,
# which reports per device and per phase (precheck, downloading, upgrading, postcheck).
#
# WHY A SCRIPT: the `scm` Terraform provider has no resource for upgrades.
#
# Usage: scm-upgrade.sh <folder> <version> [start_in_minutes=3]
#   e.g. scm-upgrade.sh AWS-HA-Transit 12.2.4
#
# [VERIFY LIVE] The response bodies of POST /software-upgrade-rules and
# /software-upgrade-schedules and the exact start-time time zone are not in the OpenAPI
# document; ids are read from the returned `id` field and the start time is given in UTC.
# Changing the version recreates nothing: it is an in-place upgrade with a reboot of each
# firewall, so GlobalProtect and the inspected path see a short interruption on failover.
###############################################################################
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scm-lib.sh
source "$HERE/scm-lib.sh"

FOLDER="${1:?usage: $0 <folder> <version> [start_in_minutes]}"
VERSION="${2:?usage: $0 <folder> <version> [start_in_minutes]}"
IN_MIN="${3:-3}"
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

# Start time: UTC, a few minutes from now (portable between macOS and Linux date).
if date -u -v+"${IN_MIN}"M +%H:%M >/dev/null 2>&1; then
  START_AT="$(date -u -v+"${IN_MIN}"M +%H:%M)"
else
  START_AT="$(date -u -d "+${IN_MIN} minutes" +%H:%M)"
fi
START_DATE="$(date -u +%F)"

# Reuse an existing rule of the same name instead of failing on a re-run.
rule_id="$(scm_api GET "$BASE/software-upgrade-rules?name=$(scm_urlenc "$NAME")" \
  | jq -r '(if type=="array" then . else (.data // []) end) | map(select(.name == "'"$NAME"'")) | first | .id // empty')"
if [ -z "$rule_id" ]; then
  rule="$(jq -nc --arg n "$NAME" --arg f "$FOLDER" \
    '{name:$n, description:"managed by scm-upgrade.sh", enabled:true,
      match_criteria:{ folders:{include:[$f]} }}')"
  scm_api POST "$BASE/software-upgrade-rules" "$rule" >/dev/null
  scm_log "created upgrade rule $NAME"
else
  scm_log "reusing upgrade rule $NAME"
fi

sched="$(jq -nc --arg n "$NAME" --arg v "$VERSION" --arg d "$START_DATE" --arg t "$START_AT" \
  '{name:$n, description:"managed by scm-upgrade.sh", enabled:true, job_type:"install",
    allow_downgrade:false, ha_orchestration:true, image_version:$v,
    install_starttime:{date:$d, at:$t}, download_starttime:{date:$d, at:$t},
    rules:[$n]}')"
resp="$(scm_api POST "$BASE/software-upgrade-schedules" "$sched")" \
  || scm_die "could not create the upgrade schedule (see the API error above)"
sid="$(jq -r '.id // empty' <<<"$resp")"
[ -n "$sid" ] || scm_die "schedule created but no id in the response: $resp"
scm_log "schedule $sid: PAN-OS $VERSION on '$FOLDER', HA orchestrated, starts $START_DATE $START_AT UTC"

# Poll the status of THIS schedule to a terminal state. The whole upgrade of a pair takes
# roughly 30-60 minutes; the API drops out while a unit reboots, so tolerate failed polls.
deadline=$(( $(date +%s) + ${UPGRADE_TIMEOUT:-5400} ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  st="$(scm_api GET "$BASE/software-upgrade-status" 2>/dev/null || true)"
  one="$(jq -c --arg s "$sid" '(if type=="array" then . else (.data // [.]) end) | map(select(.schedule_id == $s)) | first // empty' <<<"$st" 2>/dev/null || true)"
  if [ -n "$one" ]; then
    overall="$(jq -r '.overall_status // ""' <<<"$one")"
    scm_log "overall=${overall:-?}"
    jq -r '.devices[]? | "    \(.device_serial_no): " + ([.status.status_details // {} | to_entries[] | select(.value.state != null and .value.state != "") | "\(.key)=\(.value.state)"] | join(" "))' <<<"$one" >&2
    case "$overall" in
      completed) scm_log "upgrade finished"; exit 0 ;;
      failed)    scm_die "the upgrade FAILED — inspect: GET $BASE/software-upgrade-status" ;;
    esac
  else
    scm_log "no status for the schedule yet (it has not started, or the API is busy)"
  fi
  sleep 60
done
scm_die "upgrade did not finish within ${UPGRADE_TIMEOUT:-5400}s"
