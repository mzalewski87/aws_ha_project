#!/usr/bin/env bash
###############################################################################
# setup-log-collector.sh — Phase 2a log-collector setup (Panorama, XML API)
#
# Ports the Azure log-collector setup (PAN-OS-side, cloud-agnostic) to AWS:
#   1. add the EBS log volume to Panorama's logging disk-pair
#   2. bind the local Panorama Log Collector into the default Collector Group
#      (Managed Collector entry + Collector Group member) — empirical xpaths
#   3. commit + commit-all log-collector-config (pushes CG config to the LC)
#   4. (optional, disruptive) restart to (re)initialize the log DB / ES
#
# Requires the SSM tunnel to Panorama. Env:
#   PANORAMA_HOST PANORAMA_PORT PANORAMA_USER PANORAMA_PASSWORD
#   ADD_DISK (yes/no, default yes)  DO_RESTART (yes/no, default no)
###############################################################################
set -euo pipefail

H="${PANORAMA_HOST:-127.0.0.1}"; P="${PANORAMA_PORT:-44300}"
U="${PANORAMA_USER:-admin}"; PW="${PANORAMA_PASSWORD:?set PANORAMA_PASSWORD}"
ADD_DISK="${ADD_DISK:-yes}"; DO_RESTART="${DO_RESTART:-no}"
BASE="https://${H}:${P}/api/"
DEV="/config/devices/entry[@name='localhost.localdomain']"

api() { curl -sk "$@" "${BASE}"; }
key="$(api --data-urlencode "type=keygen" --data-urlencode "user=${U}" --data-urlencode "password=${PW}" \
  | sed -n 's:.*<key>\(.*\)</key>.*:\1:p')"
[ -n "${key}" ] || { echo "[lc] keygen failed"; exit 1; }

serial="$(api --data-urlencode "type=op" \
  --data-urlencode "cmd=<show><system><info></info></system></show>" --data-urlencode "key=${key}" \
  | sed -n 's:.*<serial>\(.*\)</serial>.*:\1:p')"
[ -n "${serial}" ] || { echo "[lc] could not read Panorama serial"; exit 1; }
echo "[lc] Panorama serial: ${serial}"

# 1. Add the EBS log volume to the logging disk-pair. The exact disk identifier
#    depends on how PAN-OS enumerates the EBS volume — confirm on the box with
#    `show system disk-space` / `request system disk-pair add ?`. Best-effort.
if [ "${ADD_DISK}" = "yes" ]; then
  echo "[lc] adding logging disk-pair (best-effort)"
  api --data-urlencode "type=op" \
    --data-urlencode "cmd=<request><system><disk-pair><add>A</add></disk-pair></system></request>" \
    --data-urlencode "key=${key}" | sed 's/^/[lc][disk] /' || true
fi

# 2. Managed Collector entry (local LC) + default Collector Group membership.
echo "[lc] creating local Managed Collector entry"
api --data-urlencode "type=config" --data-urlencode "action=set" \
  --data-urlencode "xpath=${DEV}/log-collector" \
  --data-urlencode "element=<entry name='${serial}'/>" --data-urlencode "key=${key}" >/dev/null

echo "[lc] binding LC into Collector Group 'default'"
api --data-urlencode "type=config" --data-urlencode "action=set" \
  --data-urlencode "xpath=${DEV}/log-collector-group" \
  --data-urlencode "element=<entry name='default'><logfwd-setting><collectors><member>${serial}</member></collectors></logfwd-setting></entry>" \
  --data-urlencode "key=${key}" >/dev/null

# 3. Commit + push Collector Group config to the LC daemon.
echo "[lc] commit"
api --data-urlencode "type=commit" --data-urlencode "cmd=<commit></commit>" --data-urlencode "key=${key}" >/dev/null
sleep 20
echo "[lc] commit-all log-collector-config"
api --data-urlencode "type=commit" \
  --data-urlencode "cmd=<commit-all><log-collector-config><log-collector-group>default</log-collector-group></log-collector-config></commit-all>" \
  --data-urlencode "key=${key}" >/dev/null

echo "[lc] current log-collector status:"
api --data-urlencode "type=op" \
  --data-urlencode "cmd=<show><log-collector><all></all></log-collector></show>" --data-urlencode "key=${key}" \
  | grep -oE '<(serial|connected|config-status|redistribution-status)>[^<]*</[^>]+>' || true

# 4. Optional disruptive restart to (re)initialize the log DB / Elasticsearch.
if [ "${DO_RESTART}" = "yes" ]; then
  echo "[lc] restarting Panorama to reinitialize the log DB (DISRUPTIVE)"
  api --data-urlencode "type=op" \
    --data-urlencode "cmd=<request><restart><system></system></restart></request>" --data-urlencode "key=${key}" || true
fi
echo "[lc] done"
