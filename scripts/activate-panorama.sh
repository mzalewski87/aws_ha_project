#!/usr/bin/env bash
###############################################################################
# activate-panorama.sh — Phase 2a step (ported from the Azure project).
#
# Panorama on AWS/Azure ships WITHOUT a serial or licenses. Until it has a
# serial + management license it cannot manage firewalls (FWs stay
# Connected=no even with valid device certs). This:
#   1. sets the serial number (`set serial-number`) — mgmt service may restart,
#   2. commits,
#   3. `request license fetch` (retry) — pulls licenses registered to the serial,
#   4. optionally fetches the Panorama DEVICE CERTIFICATE via an OTP.
#
# Panorama uses an OTP (per-serial, single-use, 60-min) for its device cert;
# FWs use the Registration PIN. The XML syntax differs from the FW's:
#   Panorama: <request><certificate><fetch><otp>X</otp></fetch></certificate></request>
#   FW:       <request><device-certificate>...   (do NOT use for Panorama)
#
# Reachability is the SSM tunnel (127.0.0.1:PANORAMA_PORT). The SSM
# port-forward-to-remote-host survives a Panorama mgmt restart (it re-dials the
# destination per connection), so we just wait for /php/login.php to answer.
#
# Env: PANORAMA_HOST PANORAMA_PORT PANORAMA_USER PANORAMA_PASSWORD
#      PANORAMA_SERIAL  [PANORAMA_DEVICE_OTP]
###############################################################################
set -u
H="${PANORAMA_HOST:-127.0.0.1}"; P="${PANORAMA_PORT:-44300}"
U="${PANORAMA_USER:-admin}"; PW="${PANORAMA_PASSWORD:?set PANORAMA_PASSWORD}"
SERIAL="${PANORAMA_SERIAL:?set PANORAMA_SERIAL}"
OTP="${PANORAMA_DEVICE_OTP:-}"
BASE="https://${H}:${P}"
ENC="$(P="$PW" python3 -c 'import urllib.parse,os;print(urllib.parse.quote(os.environ["P"],safe=""))')"

keygen() { curl -sk --max-time 20 "${BASE}/api/?type=keygen&user=${U}&password=${ENC}" 2>/dev/null | sed -n 's:.*<key>\(.*\)</key>.*:\1:p'; }
wait_api() {
  for i in $(seq 1 30); do
    c="$(curl -sk --max-time 8 -o /dev/null -w '%{http_code}' "${BASE}/php/login.php" 2>/dev/null || echo 000)"
    { [ "$c" = 200 ] || [ "$c" = 302 ]; } && { echo "  API ready (HTTP $c) [$i]"; return 0; }
    echo "  [$i/30] API HTTP $c — waiting 10s (mgmt may be restarting)..."; sleep 10
  done
  echo "  [WARN] API not stable; continuing anyway" >&2
}

echo "[activate] serial=${SERIAL}"
KEY="$(keygen)"; [ -n "$KEY" ] || { echo "[activate] ERROR: keygen failed (tunnel/creds?)"; exit 1; }

echo "[activate] set serial-number (mgmt may restart)"
curl -sk --max-time 120 "${BASE}/api/" --data-urlencode "type=op" \
  --data-urlencode "cmd=<set><serial-number>${SERIAL}</serial-number></set>" \
  --data-urlencode "key=${KEY}" 2>/dev/null | head -c 200; echo
sleep 15; wait_api; KEY="$(keygen)"

echo "[activate] commit"
curl -sk --max-time 120 "${BASE}/api/" --data-urlencode "type=commit" \
  --data-urlencode "cmd=<commit></commit>" --data-urlencode "key=${KEY}" 2>/dev/null | head -c 200; echo
sleep 30; wait_api; KEY="$(keygen)"

echo "[activate] request license fetch (retry)"
lic_ok=0
for i in $(seq 1 5); do
  R="$(curl -sk --max-time 120 "${BASE}/api/" --data-urlencode "type=op" \
    --data-urlencode "cmd=<request><license><fetch></fetch></license></request>" \
    --data-urlencode "key=${KEY}" 2>/dev/null)"
  if printf '%s' "$R" | grep -q 'status="success"'; then echo "  [OK] licenses installed"; lic_ok=1; break; fi
  echo "  [$i/5] $(printf '%s' "$R" | head -c 140) — waiting 30s"; sleep 30; wait_api; KEY="$(keygen)"
done
[ "$lic_ok" = 1 ] || echo "  [WARN] license fetch not confirmed — check CSP/serial/egress"

if [ -n "$OTP" ]; then
  echo "[activate] fetch device certificate via OTP (Panorama syntax)"
  sleep 5; wait_api; KEY="$(keygen)"
  R="$(curl -sk --max-time 60 "${BASE}/api/" --data-urlencode "type=op" \
    --data-urlencode "cmd=<request><certificate><fetch><otp>${OTP}</otp></fetch></certificate></request>" \
    --data-urlencode "key=${KEY}" 2>/dev/null)"
  echo "  fetch resp: $(printf '%s' "$R" | head -c 200)"
  JID="$(printf '%s' "$R" | grep -oE '<job>[0-9]+' | grep -oE '[0-9]+' | head -1)"
  if [ -n "$JID" ]; then
    for i in $(seq 1 12); do
      J="$(curl -sk --max-time 15 "${BASE}/api/?type=op&cmd=<show><jobs><id>${JID}</id></jobs></show>&key=${KEY}" 2>/dev/null)"
      st="$(printf '%s' "$J" | grep -oE '<status>[^<]+' | head -1)"
      echo "  job ${JID}: ${st}"
      printf '%s' "$J" | grep -qiE 'FIN|OTP is not valid' && break
      sleep 5
    done
  fi
  echo "  device-cert status:"
  curl -sk "${BASE}/api/?type=op&cmd=<show><device-certificate><info></info></device-certificate></show>&key=${KEY}" 2>/dev/null | head -c 300; echo
fi

echo "[activate] verify"
KEY="$(keygen)"
curl -sk "${BASE}/api/?type=op&cmd=<show><system><info></info></system></show>&key=${KEY}" 2>/dev/null | grep -oE '<serial>[^<]+|<sw-version>[^<]+'
echo "[activate] done"
