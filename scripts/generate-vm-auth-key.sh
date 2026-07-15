#!/usr/bin/env bash
###############################################################################
# generate-vm-auth-key.sh
#
# Generates a device-registration vm-auth-key on Panorama (XML API over the SSM
# tunnel) and writes ../panorama_vm_auth_key.auto.tfvars so Phase 1b auto-loads
# it into the FW bootstrap. Invoked by the Phase 2a workspace
# (null_resource.vm_auth_key) or standalone.
#
# Requires an active SSM port-forward to Panorama (configure-panorama.sh tunnel).
# Env: PANORAMA_HOST PANORAMA_PORT PANORAMA_USER PANORAMA_PASSWORD
#      KEY_LIFETIME OUTPUT_PATH
###############################################################################
set -euo pipefail

H="${PANORAMA_HOST:-127.0.0.1}"
P="${PANORAMA_PORT:-44300}"
U="${PANORAMA_USER:-admin}"
PW="${PANORAMA_PASSWORD:?set PANORAMA_PASSWORD}"
L="${KEY_LIFETIME:-168}"
OUT="${OUTPUT_PATH:-../panorama_vm_auth_key.auto.tfvars}"
BASE="https://${H}:${P}/api/"

echo "[vm-auth-key] requesting API key from ${H}:${P}"
api_key="$(curl -sk "${BASE}?type=keygen&user=${U}&password=${PW}" \
  | sed -n 's:.*<key>\(.*\)</key>.*:\1:p')"
[ -n "${api_key}" ] || { echo "[vm-auth-key] ERROR: keygen failed (creds/tunnel?)"; exit 1; }

cmd="<request><bootstrap><vm-auth-key><generate><lifetime>${L}</lifetime></generate></vm-auth-key></bootstrap></request>"
echo "[vm-auth-key] generating key (lifetime ${L}h)"
resp="$(curl -sk --data-urlencode "type=op" \
  --data-urlencode "cmd=${cmd}" \
  --data-urlencode "key=${api_key}" "${BASE}")"

# Response: "<result>VM auth key <15-digit-key> generated. Expires at: ...".
# Extract the digits after "VM auth key " (NOT a fragment of the expiry time).
key="$(printf '%s' "${resp}" | sed -n 's/.*VM auth key \([0-9][0-9]*\).*/\1/p' | head -1)"
[ -n "${key}" ] || { echo "[vm-auth-key] ERROR: could not parse key from: ${resp}"; exit 1; }

printf 'panorama_vm_auth_key = "%s"\n' "${key}" > "${OUT}"
echo "[vm-auth-key] wrote ${OUT}"
