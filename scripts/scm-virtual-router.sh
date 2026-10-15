#!/usr/bin/env bash
###############################################################################
# scm-virtual-router.sh — create/update the legacy virtual router in an SCM
# folder via REST.
#
# WHY REST and not Terraform: the `scm` provider (v1.0.x) only models the
# Advanced Routing Engine `logical_router`. ARE needs
# plugin-op-commands=advance-routing:enable and changes the routing engine under
# the AWS HA plugin (route-table failover), which is live-verified ONLY with the
# legacy virtual router in path A. The OpenAPI does expose /virtual-routers, so
# we keep the proven engine and drive it from here. Idempotent: PUT if the router
# already exists in the folder, POST otherwise.
#
# Routes use the folder variables from phase2-scm-config ($untrust_gw, $trust_gw)
# so the same router works on both firewalls.
#
# Usage: scm-virtual-router.sh <folder> [internal_supernet=10.0.0.0/8]
# Interfaces are the Terraform-managed folder interfaces, referenced by their SCM
# `$variable` names ($untrust_if -> ethernet1/3, $trust_if -> ethernet1/2,
# $gp_tunnel -> tunnel.1, $gp_loopback -> loopback.1).
###############################################################################
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scm-lib.sh
source "$HERE/scm-lib.sh"

FOLDER="${1:?usage: $0 <folder> [internal_supernet]}"
SUPERNET="${2:-10.0.0.0/8}"
VR_NAME="${VR_NAME:-vr-aws}"

body="$(jq -nc --arg n "$VR_NAME" --arg sup "$SUPERNET" '
  {
    name: $n,
    description: "AWS transit VR (managed by scm-virtual-router.sh)",
    interface: ["$untrust_if", "$trust_if", "$gp_tunnel", "$gp_loopback"],
    routing_table: { ip: { static_route: [
      { name:"default-to-igw",  destination:"0.0.0.0/0", interface:"$untrust_if", nexthop:{ ip_address:"$untrust_gw" } },
      { name:"internal-to-tgw", destination:$sup,        interface:"$trust_if", nexthop:{ ip_address:"$trust_gw" } }
    ] } }
  }')"

enc="$(scm_urlenc "$FOLDER")"
existing="$(scm_api GET "/config/network/v1/virtual-routers?folder=${enc}&name=$(scm_urlenc "$VR_NAME")" \
  | jq -r --arg f "$FOLDER" '(.data // []) | map(select(.folder == $f)) | first | .id // empty')"

if [ -n "$existing" ]; then
  scm_log "updating virtual router '$VR_NAME' ($existing) in folder '$FOLDER'"
  scm_api PUT "/config/network/v1/virtual-routers/${existing}?folder=${enc}" "$body" >/dev/null
else
  scm_log "creating virtual router '$VR_NAME' in folder '$FOLDER'"
  scm_api POST "/config/network/v1/virtual-routers?folder=${enc}" "$body" >/dev/null
fi
scm_log "done — verify: GET /config/network/v1/virtual-routers?folder=${FOLDER}"
