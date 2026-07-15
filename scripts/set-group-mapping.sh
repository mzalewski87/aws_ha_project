#!/usr/bin/env bash
###############################################################################
# set-group-mapping.sh — Phase GP helper
#
# Creates the LDAP GROUP-MAPPING on Panorama so PAN-OS can resolve AD group
# membership and the GlobalProtect auth profile can gate access on a group
# (the auth-profile allow-list references the group DN). The panos provider (v2)
# has NO resource for group-mapping, so it is set via the raw XML API — same
# pattern as set-gp-tunnel-node.sh.
#
# The mapping lives at the template vsys level:
#   .../template/entry[@name=TPL]/config/devices/entry[@name=localhost.localdomain]
#       /vsys/entry[@name=VSYS]/group-mapping/entry[@name=MAP_NAME]
# It points at the existing LDAP server profile (LDAP_PROFILE) and restricts the
# fetched groups to GROUP_DN via <group-include-list>. AD schema defaults apply
# (the server profile is type active-directory).
#
# Inputs (env):
#   PANORAMA_HOST (default 127.0.0.1), PANORAMA_PORT (default 44300),
#   PANORAMA_USER (default admin), PANORAMA_PASSWORD (required),
#   TEMPLATE_NAME (required), VSYS (default vsys1),
#   MAP_NAME (default gp-group-map), LDAP_PROFILE (required, e.g. gp-ad-ldap),
#   GROUP_DN (required, e.g. cn=vpnusers,cn=users,dc=panw,dc=labs)
###############################################################################
set -euo pipefail

H="${PANORAMA_HOST:-127.0.0.1}"; P="${PANORAMA_PORT:-44300}"
U="${PANORAMA_USER:-admin}"; PW="${PANORAMA_PASSWORD:?set PANORAMA_PASSWORD}"
TPL="${TEMPLATE_NAME:?set TEMPLATE_NAME}"
VSYS="${VSYS:-vsys1}"
MAP_NAME="${MAP_NAME:-gp-group-map}"
LDAP_PROFILE="${LDAP_PROFILE:?set LDAP_PROFILE}"
GROUP_DN="${GROUP_DN:?set GROUP_DN}"
# How often the firewalls re-read group membership from AD. LOW (60s) so a user
# newly added to the group can connect within ~a minute — PAN-OS's default 3600s
# (1h) makes new members wait up to an hour, which is wrong for a test lab where
# people add colleagues on the fly. Raise it for a large/production directory.
UPDATE_INTERVAL="${GROUP_UPDATE_INTERVAL:-60}"
BASE="https://${H}:${P}/api/"

key="$(curl -sk "${BASE}?type=keygen&user=${U}&password=${PW}" | sed -n 's:.*<key>\(.*\)</key>.*:\1:p')"
[ -n "${key}" ] || { echo "[group-mapping] keygen failed" >&2; exit 1; }

xpath="/config/devices/entry[@name='localhost.localdomain']/template/entry[@name='${TPL}']/config/devices/entry[@name='localhost.localdomain']/vsys/entry[@name='${VSYS}']/group-mapping/entry[@name='${MAP_NAME}']"
element="<server-profile>${LDAP_PROFILE}</server-profile><update-interval>${UPDATE_INTERVAL}</update-interval><group-include-list><member>${GROUP_DN}</member></group-include-list>"

resp="$(curl -sk --max-time 30 -G "${BASE}" \
  --data-urlencode "type=config" --data-urlencode "action=set" \
  --data-urlencode "xpath=${xpath}" --data-urlencode "element=${element}" \
  --data-urlencode "key=${key}")"

if printf '%s' "${resp}" | grep -q 'status="success"'; then
  echo "[group-mapping] ${MAP_NAME}: profile=${LDAP_PROFILE} include=${GROUP_DN} : OK"
else
  echo "[group-mapping] FAILED: ${resp}" >&2
  exit 1
fi
