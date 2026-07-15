#!/usr/bin/env bash
###############################################################################
# check-panorama.sh — quick Panorama reachability/status via the SSM tunnel.
# Env: PANORAMA_HOST PANORAMA_PORT PANORAMA_USER PANORAMA_PASSWORD
###############################################################################
set -euo pipefail
H="${PANORAMA_HOST:-127.0.0.1}"; P="${PANORAMA_PORT:-44300}"
U="${PANORAMA_USER:-admin}"; PW="${PANORAMA_PASSWORD:?set PANORAMA_PASSWORD}"
BASE="https://${H}:${P}/api/"

code="$(curl -sk -o /dev/null -w '%{http_code}' "${BASE%/}/../php/login.php" || true)"
echo "login page HTTP ${code}"
key="$(curl -sk "${BASE}?type=keygen&user=${U}&password=${PW}" | sed -n 's:.*<key>\(.*\)</key>.*:\1:p')"
[ -n "${key}" ] || { echo "keygen failed — tunnel up? creds ok?"; exit 1; }
echo "API key OK. System info:"
curl -sk --data-urlencode "type=op" \
  --data-urlencode "cmd=<show><system><info></info></system></show>" \
  --data-urlencode "key=${key}" "${BASE}" \
  | grep -oE '<(hostname|sw-version|serial|uptime)>[^<]*</(hostname|sw-version|serial|uptime)>' || true
