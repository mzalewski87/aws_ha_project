#!/usr/bin/env bash
###############################################################################
# deploy-gp-client.sh — download + ACTIVATE the GlobalProtect app package on
# each managed firewall, so the portal can actually serve the agent installer.
#
# Without this, a user who logs into the portal and clicks "Download" gets a
# text file errors.txt containing "Could not find file" — the portal has no
# activated GP app package to hand out (PANW KB kA10g000000ClrhCAC /
# kA10g000000ClroCAC). Download alone is not enough; the package must be
# ACTIVATED (only one version active at a time).
#
# We drive it through Panorama's op-command proxy (&target=<serial>) over the
# same SSM tunnel + XML API used by configure-panorama.sh, so no direct firewall
# access is needed. Each firewall must be able to reach the PANW update servers
# (updates.paloaltonetworks.com) via its NAT egress for check/download.
#
# Env:
#   PANORAMA_HOST/PORT/USER/PASSWORD  — Panorama API (via the tunnel)
#   SERIALS            — space/comma-separated firewall serials (required)
#   GP_CLIENT_VERSION  — version to install, or "latest" (default) to resolve
#                        the highest available from `... software info`
#   POLL_TRIES         — per-job poll budget (default 240 x 5s = 20 min)
###############################################################################
set -euo pipefail

H="${PANORAMA_HOST:-127.0.0.1}"; P="${PANORAMA_PORT:-44300}"
U="${PANORAMA_USER:-admin}"; PW="${PANORAMA_PASSWORD:?PANORAMA_PASSWORD required}"
SERIALS="${SERIALS:?SERIALS required (space/comma-separated firewall serials)}"
WANT="${GP_CLIENT_VERSION:-latest}"
POLL_TRIES="${POLL_TRIES:-240}"
BASE="https://${H}:${P}/api/"

# normalize separators to whitespace
SERIALS="$(printf '%s' "${SERIALS}" | tr ',' ' ')"

key="$(curl -sk "${BASE}?type=keygen&user=${U}&password=${PW}" | sed -n 's:.*<key>\(.*\)</key>.*:\1:p')"
[ -n "${key}" ] || { echo "[gp-client] could not get API key" >&2; exit 1; }

# op command against a specific managed firewall (Panorama proxies via target=)
op() { # $1 = serial, $2 = cmd xml -> prints response
  curl -sk --data-urlencode "type=op" --data-urlencode "cmd=$2" \
    --data-urlencode "target=$1" --data-urlencode "key=${key}" "${BASE}"
}

# Wait for a firewall job to reach FIN. Job status is the FIRST <status> in the
# response (a per-device/step status may follow) — grep -o|head -1, never a
# greedy sed. Success = FIN and no <result>FAIL.
wait_job() { # $1 = serial, $2 = job id
  local serial="$1" jid="$2" xml status tries=0
  while [ "${tries}" -lt "${POLL_TRIES}" ]; do
    xml="$(op "${serial}" "<show><jobs><id>${jid}</id></jobs></show>")"
    status="$(printf '%s' "${xml}" | grep -oE '<status>[^<]*</status>' | head -1 | sed -E 's:</?status>::g')"
    if [ "${status}" = "FIN" ]; then
      if printf '%s' "${xml}" | grep -oE '<result>[^<]*</result>' | grep -q '<result>FAIL</result>'; then
        echo "[gp-client] ${serial}: job ${jid} FAILED:" >&2; printf '%s\n' "${xml}" >&2; return 1
      fi
      return 0
    fi
    tries=$((tries + 1)); sleep 5
  done
  echo "[gp-client] ${serial}: job ${jid} did not reach FIN in $((POLL_TRIES * 5 / 60)) min" >&2
  return 1
}

# submit an async op that returns a <job>, then wait for it
run_job() { # $1 = serial, $2 = label, $3 = cmd xml
  local serial="$1" label="$2" cmdxml="$3" resp jid
  resp="$(op "${serial}" "${cmdxml}")"
  if printf '%s' "${resp}" | grep -q 'status="error"'; then
    echo "[gp-client] ${serial}: ${label} submit error:" >&2; printf '%s\n' "${resp}" >&2; return 1
  fi
  jid="$(printf '%s' "${resp}" | sed -n 's:.*<job>\([0-9]*\)</job>.*:\1:p' | head -1)"
  if [ -z "${jid}" ]; then
    # no job id: often "already downloaded/activated" or a synchronous OK
    echo "[gp-client] ${serial}: ${label} — no job queued (likely already done)"
    return 0
  fi
  echo "[gp-client] ${serial}: ${label} job ${jid} ..."
  wait_job "${serial}" "${jid}"
}

resolve_version() { # $1 = serial -> highest available version to stdout
  local serial="$1" xml
  xml="$(op "${serial}" "<request><global-protect-client><software><info></info></software></global-protect-client></request>")"
  printf '%s' "${xml}" | grep -oE '<version>[0-9][0-9.]*</version>' | sed -E 's:</?version>::g' \
    | sort -V | tail -1
}

rc=0
for serial in ${SERIALS}; do
  echo "=== ${serial} ==="
  run_job "${serial}" "software check" \
    "<request><global-protect-client><software><check></check></software></global-protect-client></request>" || { rc=1; continue; }

  ver="${WANT}"
  if [ "${ver}" = "latest" ]; then
    ver="$(resolve_version "${serial}")"
    [ -n "${ver}" ] || { echo "[gp-client] ${serial}: could not resolve latest version" >&2; rc=1; continue; }
  fi
  echo "[gp-client] ${serial}: target GP app version ${ver}"

  run_job "${serial}" "download ${ver}" \
    "<request><global-protect-client><software><download><version>${ver}</version></download></software></global-protect-client></request>" || { rc=1; continue; }
  run_job "${serial}" "activate ${ver}" \
    "<request><global-protect-client><software><activate><version>${ver}</version></activate></software></global-protect-client></request>" || { rc=1; continue; }
  echo "[gp-client] ${serial}: GP app ${ver} downloaded + activated"
done

[ "${rc}" -eq 0 ] && echo "[gp-client] all firewalls done" || echo "[gp-client] one or more firewalls FAILED" >&2
exit "${rc}"
