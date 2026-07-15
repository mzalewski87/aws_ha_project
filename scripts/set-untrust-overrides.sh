#!/usr/bin/env bash
###############################################################################
# set-untrust-overrides.sh — Phase 2a helper
#
# Sets the per-device value of the untrust-primary template variable
# ($fw_untrust_ip) on the template stack, one override per firewall serial.
#
# WHY a script instead of the panos provider: panos_template_variable with
# location.template_stack.panorama_device is broken for MORE THAN ONE device —
# two such resources both try to create the shared `devices` node under the
# template stack and PAN-OS rejects the second with "At most 1 occurrence is
# allowed for devices/entry". The raw XML API handles the same overrides fine
# (each writes its own devices/entry[@name=SERIAL]/variable subtree), so we set
# them directly here, the same pattern as configure-panorama.sh / configure-ha.sh.
#
# The template-level default of the variable is still managed by the provider
# (panos_template_variable.untrust_ip_default) — that single-occurrence case
# works; only the per-device overrides need this workaround.
#
# Inputs (env):
#   PANORAMA_HOST (default 127.0.0.1), PANORAMA_PORT (default 44300),
#   PANORAMA_USER (default admin), PANORAMA_PASSWORD (required),
#   TEMPLATE_STACK (required), VAR_NAME (default $fw_untrust_ip),
#   FW_OVERRIDES: JSON object { "<serial>": "<ip/mask>", ... }
###############################################################################
set -euo pipefail

H="${PANORAMA_HOST:-127.0.0.1}"; P="${PANORAMA_PORT:-44300}"
U="${PANORAMA_USER:-admin}"; PW="${PANORAMA_PASSWORD:?set PANORAMA_PASSWORD}"
STK="${TEMPLATE_STACK:?set TEMPLATE_STACK}"
VAR_NAME="${VAR_NAME:-\$fw_untrust_ip}"
OVERRIDES="${FW_OVERRIDES:?set FW_OVERRIDES (JSON serial->ip/mask)}"
BASE="https://${H}:${P}/api/"

key="$(curl -sk "${BASE}?type=keygen&user=${U}&password=${PW}" | sed -n 's:.*<key>\(.*\)</key>.*:\1:p')"
[ -n "${key}" ] || { echo "[overrides] keygen failed" >&2; exit 1; }

# Iterate serial->ip pairs from the JSON map.
while IFS=$'\t' read -r serial ip; do
  [ -n "${serial}" ] || continue
  xpath="/config/devices/entry[@name='localhost.localdomain']/template-stack/entry[@name='${STK}']/devices/entry[@name='${serial}']/variable/entry[@name='${VAR_NAME}']"
  resp="$(curl -sk --max-time 30 -G "${BASE}" \
    --data-urlencode "type=config" --data-urlencode "action=set" \
    --data-urlencode "xpath=${xpath}" \
    --data-urlencode "element=<type><ip-netmask>${ip}</ip-netmask></type>" \
    --data-urlencode "key=${key}")"
  if printf '%s' "${resp}" | grep -q 'status="success"'; then
    echo "[overrides] ${serial} -> ${ip} : OK"
  else
    echo "[overrides] ${serial} -> ${ip} : FAILED: ${resp}" >&2
    exit 1
  fi
done < <(printf '%s' "${OVERRIDES}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(f"{k}\t{v}" for k,v in d.items()))')

echo "[overrides] done"
