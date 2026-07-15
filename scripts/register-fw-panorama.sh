#!/usr/bin/env bash
###############################################################################
# register-fw-panorama.sh — Phase 2b
#
# After the FWs boot and register to Panorama with the vm-auth-key, they appear
# as managed devices. This script reads their serials from Panorama, adds them to
# the device group + template stack, and commit-alls so config is pushed.
#
# Requires the SSM tunnel to Panorama (configure-panorama.sh tunnel).
# Env: PANORAMA_HOST PANORAMA_PORT PANORAMA_USER PANORAMA_PASSWORD
#      DEVICE_GROUP TEMPLATE_STACK
###############################################################################
set -euo pipefail

H="${PANORAMA_HOST:-127.0.0.1}"; P="${PANORAMA_PORT:-44300}"
U="${PANORAMA_USER:-admin}"; PW="${PANORAMA_PASSWORD:?set PANORAMA_PASSWORD}"
DG="${DEVICE_GROUP:-AWS-Transit-DG}"; TS="${TEMPLATE_STACK:-AWS-Transit-Stack}"
BASE="https://${H}:${P}/api/"

key="$(curl -sk "${BASE}?type=keygen&user=${U}&password=${PW}" \
  | sed -n 's:.*<key>\(.*\)</key>.*:\1:p')"
[ -n "${key}" ] || { echo "[register] keygen failed"; exit 1; }

echo "[register] reading connected device serials from Panorama"
devs="$(curl -sk --data-urlencode "type=op" \
  --data-urlencode "cmd=<show><devices><connected></connected></devices></show>" \
  --data-urlencode "key=${key}" "${BASE}")"
serials="$(printf '%s' "${devs}" | grep -oE '<serial>[^<]+</serial>' | sed -E 's:</?serial>::g' | sort -u)"
[ -n "${serials}" ] || { echo "[register] no connected devices yet — wait for the FWs to register"; exit 1; }
echo "[register] serials:"; echo "${serials}" | sed 's/^/  - /'

for s in ${serials}; do
  echo "[register] adding ${s} to device group ${DG}"
  curl -sk --data-urlencode "type=config" --data-urlencode "action=set" \
    --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/device-group/entry[@name='${DG}']/devices" \
    --data-urlencode "element=<entry name='${s}'/>" --data-urlencode "key=${key}" "${BASE}" >/dev/null
  echo "[register] adding ${s} to template stack ${TS}"
  curl -sk --data-urlencode "type=config" --data-urlencode "action=set" \
    --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/template-stack/entry[@name='${TS}']/devices" \
    --data-urlencode "element=<entry name='${s}'/>" --data-urlencode "key=${key}" "${BASE}" >/dev/null
done

echo "[register] commit + commit-all"
DEVICE_GROUP="${DG}" TEMPLATE_STACK="${TS}" PANORAMA_HOST="${H}" PANORAMA_PORT="${P}" \
  PANORAMA_USER="${U}" PANORAMA_PASSWORD="${PW}" "$(dirname "$0")/configure-panorama.sh" commit
echo "[register] done"
