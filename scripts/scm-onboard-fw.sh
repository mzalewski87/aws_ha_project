#!/usr/bin/env bash
###############################################################################
# scm-onboard-fw.sh — path-B equivalent of register-fw-panorama.sh.
#
# With SCM there is no serial-registration step: the firewalls bootstrap with
# panorama-server=cloud + the auto-registration PIN and appear in the tenant on
# their own. What is left is to (1) wait until they are connected, (2) move them
# into the deployment folder, and (3) hand their per-device addresses to
# Terraform.
#
# ORDER (it is a two-pass apply, because the folder must exist before devices
# can be moved into it, and per-device variable overrides need the devices in it):
#   1. phase2-scm-config:  terraform apply -parallelism=4        (folder + defaults)
#   2. this script                                               (move + tfvars)
#   3. phase2-scm-config:  terraform apply -parallelism=4        (device overrides)
#
# Usage:
#   scm-onboard-fw.sh <folder> <serial|hostname>=<trust_cidr>,<untrust_cidr> [...]
#   e.g. scm-onboard-fw.sh AWS-HA-Transit <serial1>=10.10.20.11/24,10.10.10.11/24 \
#                                         <serial2>=10.10.20.12/24,10.10.10.12/24
#   KEY = the firewall's SERIAL or its MANAGEMENT IP (root output fw_mgmt_private_ips; only a
#   connected device matches an IP). Not the init-cfg hostname: DHCP overrides it
#   (ip-10-10-0-11). The tfvars file is always keyed by serial.
#
# Env: SCM_TSG_ID SCM_CLIENT_ID SCM_CLIENT_SECRET (see scm-lib.sh),
#      WAIT_MINUTES (default 30), OUT_FILE (default
#      phase2-scm-config/fw_devices.auto.tfvars.json — git-ignored).
###############################################################################
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scm-lib.sh
source "$HERE/scm-lib.sh"

[ "$#" -ge 2 ] || scm_die "usage: $0 <folder> <serial>=<trust_cidr>,<untrust_cidr>[,<floating_cidr>,<trust_gw>,<untrust_gw>] [...]"
FOLDER="$1"; shift
WAIT_MINUTES="${WAIT_MINUTES:-30}"
OUT_FILE="${OUT_FILE:-$HERE/../phase2-scm-config/fw_devices.auto.tfvars.json}"

# Existing entries are KEPT (a second region's pair is added next to the first one); a serial
# given again is replaced. REPLACE=1 starts from an empty map instead.
devices_json='{}'
if [ "${REPLACE:-0}" != "1" ] && [ -s "$OUT_FILE" ]; then
  devices_json="$(jq -c '.fw_devices // {}' "$OUT_FILE")" || scm_die "cannot read $OUT_FILE"
fi
for spec in "$@"; do
  host="${spec%%=*}"; addrs="${spec#*=}"
  IFS=, read -r trust untrust floating trust_gw untrust_gw <<<"$addrs"
  [ -n "$host" ] && [ -n "${trust:-}" ] && [ -n "${untrust:-}" ] && [ "$host" != "$spec" ] \
    || scm_die "bad spec '$spec' (want serial=trust_cidr,untrust_cidr[,floating_cidr,trust_gw,untrust_gw])"
  if [ -n "${floating:-}${trust_gw:-}${untrust_gw:-}" ] && { [ -z "${floating:-}" ] || [ -z "${trust_gw:-}" ] || [ -z "${untrust_gw:-}" ]; }; then
    scm_die "bad spec '$spec': give all three of floating_cidr,trust_gw,untrust_gw or none (they override the Region-A folder defaults, e.g. for a Region B pair)"
  fi

  scm_log "waiting for '$host' to appear and connect (up to ${WAIT_MINUTES} min)..."
  dev=""; waited=0
  while [ "$waited" -lt $((WAIT_MINUTES * 60)) ]; do
    dev="$(scm_device_by_hostname "$host" || true)"
    if [ -n "$dev" ] && [ "$(jq -r '.is_connected // false' <<<"$dev")" = "true" ]; then break; fi
    dev=""; sleep 20; waited=$((waited + 20))
  done
  [ -n "$dev" ] || scm_die "'$host' never showed up connected in tenant ${SCM_TSG_ID}. Check: licensing (auth code credits), device-certificate PIN (60-min TTL), outbound HTTPS from the mgmt subnet."

  id="$(jq -r '.id' <<<"$dev")"
  # SCM names a device by its serial (verified live); the scm_variable `device` attribute takes it.
  serial="$(jq -r '.name' <<<"$dev")"
  scm_log "$host -> device id=$id name/serial=$serial model=$(jq -r '.model // "?"' <<<"$dev") sw=$(jq -r '.software_version // "?"' <<<"$dev") folder=$(jq -r '.folder // "?"' <<<"$dev")"

  if [ "$(jq -r '.folder // ""' <<<"$dev")" != "$FOLDER" ]; then
    scm_api PUT "/config/setup/v1/devices/${id}" "$(jq -nc --arg f "$FOLDER" '{folder:$f}')" >/dev/null \
      || scm_die "could not move $host into folder '$FOLDER' (does it exist? run the first terraform apply)"
    scm_log "$host moved into folder '$FOLDER'"
  else
    scm_log "$host already in folder '$FOLDER'"
  fi

  devices_json="$(jq -c --arg s "$serial" --arg t "$trust" --arg u "$untrust" \
    --arg f "${floating:-}" --arg tg "${trust_gw:-}" --arg ug "${untrust_gw:-}" \
    '. + {($s): ({trust_ip:$t, untrust_ip:$u}
                 + (if $f != "" then {untrust_floating:$f, trust_gw:$tg, untrust_gw:$ug} else {} end))}' <<<"$devices_json")"
done

# Atomic write, owner-only (no secrets inside, but it names the devices).
tmp="$(mktemp "${OUT_FILE}.XXXXXX")"
jq -n --argjson d "$devices_json" '{fw_devices: $d}' > "$tmp"
mv "$tmp" "$OUT_FILE"
scm_log "wrote $OUT_FILE:"; jq -c . "$OUT_FILE" >&2
scm_log "next: terraform -chdir=phase2-scm-config apply -parallelism=4"
