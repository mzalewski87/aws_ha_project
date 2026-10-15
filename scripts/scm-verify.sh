#!/usr/bin/env bash
###############################################################################
# scm-verify.sh — READ-ONLY health report for path B. Changes nothing.
#
#   * devices in the folder: connected? PAN-OS version, device certificate,
#     HA state / peer state (the SCM view of `show high-availability state`)
#   * security rules of the folder in evaluation order (pre, then post) — the
#     rules are separate Terraform resources, so ORDER must be eyeballed once:
#     the Guacamole/GP allows must come before deny-all.
#
# Usage: scm-verify.sh [folder]      (default folder: AWS-HA-Transit)
###############################################################################
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scm-lib.sh
source "$HERE/scm-lib.sh"

FOLDER="${1:-AWS-HA-Transit}"
enc="$(scm_urlenc "$FOLDER")"

echo "== devices in folder '$FOLDER'"
scm_api GET "/config/setup/v1/devices?limit=500" | jq -r --arg f "$FOLDER" '
  (.data // []) | map(select(.folder == $f)) |
  if length == 0 then "  (none)" else
    .[] | "  \(.hostname // .name)  serial=\(.name)  connected=\(.is_connected)  sw=\(.software_version // "?")  cert=\(.dev_cert_detail // "?")  ha=\(.ha_state // "-")  peer=\(.ha_peer_state // "-") (\(.ha_peer_serial // "-"))"
  end'

for rb in pre post; do
  echo "== security rules, rulebase=$rb"
  scm_api GET "/config/security/v1/security-rules?folder=${enc}&position=${rb}&limit=200" 2>/dev/null \
    | jq -r '(.data // []) | to_entries[] | "  \(.key + 1). \(.value.name)  \(.value.action)  \(.value.from // [] | join(","))->\(.value.to // [] | join(","))"' \
    || echo "  (could not read — check the folder name and API path)"
done
