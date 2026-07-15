#!/usr/bin/env bash
###############################################################################
# set-gp-local-users.sh — create GP local users with a PROPERLY HASHED password.
#
# WHY this exists (load-bearing): the panos_local_user provider writes its
# `password` attribute VERBATIM into PAN-OS's <phash> element WITHOUT hashing it.
# Passing a plaintext password therefore stores the plaintext AS the hash, and
# every GP login returns auth-failed (HTTP 512, X-Private-Pan-Globalprotect:
# auth-failed) because the firewall hashes the entered password and compares it
# to the plaintext string — so local logins never work with a plaintext
# password. This script hashes each password (openssl passwd -1 =
# MD5-crypt, which PAN-OS accepts) and sets a valid <phash> via the XML API, in
# the vsys1 local-user-database (where the local-database auth profile looks).
#
# Env:
#   PANORAMA_HOST/PORT/USER/PASSWORD  — Panorama API (via the SSM tunnel)
#   TEMPLATE_NAME (default AWS-Transit-Template), VSYS (default vsys1)
#   GP_LOCAL_USERS  — JSON object {username: plaintext_password, ...}
###############################################################################
set -euo pipefail

H="${PANORAMA_HOST:-127.0.0.1}"; P="${PANORAMA_PORT:-44300}"
U="${PANORAMA_USER:-admin}"; PW="${PANORAMA_PASSWORD:?PANORAMA_PASSWORD required}"
TPL="${TEMPLATE_NAME:-AWS-Transit-Template}"; VSYS="${VSYS:-vsys1}"
USERS_JSON="${GP_LOCAL_USERS:?GP_LOCAL_USERS required (JSON object user=>password)}"
BASE="https://${H}:${P}/api/"

key="$(curl -sk "${BASE}?type=keygen&user=${U}&password=${PW}" | sed -n 's:.*<key>\(.*\)</key>.*:\1:p')"
[ -n "${key}" ] || { echo "[gp-users] no API key" >&2; exit 1; }

DB="/config/devices/entry[@name='localhost.localdomain']/template/entry[@name='${TPL}']/config/devices/entry[@name='localhost.localdomain']/vsys/entry[@name='${VSYS}']/local-user-database/user"

# iterate user=>password from the JSON
printf '%s' "${USERS_JSON}" | python3 -c "import json,sys; [print(u+'\t'+p) for u,p in json.load(sys.stdin).items()]" | \
while IFS=$'\t' read -r user pass; do
  [ -n "${user}" ] || continue
  phash="$(openssl passwd -1 "${pass}")"
  resp="$(curl -sk "${BASE}" \
    --data-urlencode "type=config" --data-urlencode "action=set" \
    --data-urlencode "xpath=${DB}/entry[@name='${user}']" \
    --data-urlencode "element=<phash>${phash}</phash>" \
    --data-urlencode "key=${key}")"
  if printf '%s' "${resp}" | grep -q 'status="success"'; then
    echo "[gp-users] ${user}: phash set OK"
  else
    echo "[gp-users] ${user}: FAILED: ${resp}" >&2; exit 1
  fi
done
echo "[gp-users] done"
