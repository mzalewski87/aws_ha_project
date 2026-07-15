#!/usr/bin/env bash
###############################################################################
# set-gp-tunnel-node.sh — Phase GP helper
#
# Creates the NETWORK-SIDE GlobalProtect gateway tunnel node:
#   network/tunnel/global-protect-gateway/entry[@name=...]
# with a <tunnel-interface> and <local-address>. This is the second of the TWO
# config subtrees a tunnel-mode GP gateway needs. The first (policy) subtree —
# vsys/.../global-protect/global-protect-gateway — is written by the panos
# provider (panos_globalprotect_gateway). The provider / pango SDK has NO model
# for network/tunnel/global-protect-gateway, so it CANNOT create this node.
#
# WHY it's mandatory: with tunnel-mode=yes, PAN-OS validates the gateway's
# <remote-user-tunnel> (the tunnel interface) as a cross-reference to a
# <tunnel-interface> bound in THIS network-side node. Without it, every commit
# fails on the firewall (not Panorama) with, in order:
#   - "<local-address> tag does not exist ... gp_broker phase 1 failure"
#     (the tunnel's local-address lives in this node, which was missing), then
#   - "remote-user-tunnel '<tun>' is not a valid reference" (no node to resolve).
# The fix mirrors PANW's own GP config template
# (PaloAltoNetworks/globalprotect-okta) and KB kA14u000000sY3CCAU.
#
# Load-bearing details:
#   - The tunnel interface (<tunnel-interface>) MUST be in a virtual router, or
#     the commit fails "Tunnel Interface <tun> has no virtual-router configured".
#   - The client IP pool must be in EXACTLY ONE place — the policy subtree's
#     remote-user-tunnel-configs — NOT here too, or the commit fails
#     "gateway-level IP pool should not co-exist with client config level IP
#     pool (Module: rasmgr)". So this node carries NO <ip-pool>.
#
# Inputs (env):
#   PANORAMA_HOST (default 127.0.0.1), PANORAMA_PORT (default 44300),
#   PANORAMA_USER (default admin), PANORAMA_PASSWORD (required),
#   TEMPLATE_NAME (required), NODE_NAME (required — the network-side node name),
#   TUNNEL_INTERFACE (required, e.g. tunnel.1),
#   LOCAL_INTERFACE (required, the dataplane interface GP binds, e.g. ethernet1/3)
###############################################################################
set -euo pipefail

H="${PANORAMA_HOST:-127.0.0.1}"; P="${PANORAMA_PORT:-44300}"
U="${PANORAMA_USER:-admin}"; PW="${PANORAMA_PASSWORD:?set PANORAMA_PASSWORD}"
TPL="${TEMPLATE_NAME:?set TEMPLATE_NAME}"
NODE="${NODE_NAME:?set NODE_NAME}"
TUN="${TUNNEL_INTERFACE:?set TUNNEL_INTERFACE}"
LIF="${LOCAL_INTERFACE:?set LOCAL_INTERFACE}"
BASE="https://${H}:${P}/api/"

key="$(curl -sk "${BASE}?type=keygen&user=${U}&password=${PW}" | sed -n 's:.*<key>\(.*\)</key>.*:\1:p')"
[ -n "${key}" ] || { echo "[gp-tunnel-node] keygen failed" >&2; exit 1; }

xpath="/config/devices/entry[@name='localhost.localdomain']/template/entry[@name='${TPL}']/config/devices/entry[@name='localhost.localdomain']/network/tunnel/global-protect-gateway/entry[@name='${NODE}']"
element="<local-address><interface>${LIF}</interface><ip-address-family>ipv4</ip-address-family></local-address><tunnel-interface>${TUN}</tunnel-interface>"

resp="$(curl -sk --max-time 30 -G "${BASE}" \
  --data-urlencode "type=config" --data-urlencode "action=set" \
  --data-urlencode "xpath=${xpath}" --data-urlencode "element=${element}" \
  --data-urlencode "key=${key}")"

if printf '%s' "${resp}" | grep -q 'status="success"'; then
  echo "[gp-tunnel-node] ${NODE}: tunnel-interface=${TUN} local=${LIF} : OK"
else
  echo "[gp-tunnel-node] FAILED: ${resp}" >&2
  exit 1
fi
