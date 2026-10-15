#!/usr/bin/env bash
###############################################################################
# scm-ha.sh — native PAN-OS Active/Passive HA, configured FROM Strata Cloud
# Manager (path-B replacement for configure-ha.sh's per-firewall SSH).
#
# Unlike Panorama (where HA is device-local and the `panos` provider has no HA
# resources), the SCM device-settings API has /ha-configurations — one call per
# device. The `scm` Terraform provider does not wrap it, hence this script.
#
# Mirrors the settings that were live-verified in path A (configure-ha.sh):
#   group-id 1, mode active-passive, preemptive NO (PANW's explicit guidance for
#   VM-Series on AWS), HA1 on the management port, HA2 on ethernet1/1 with the
#   HA2 ENI's address (ethernet1/1 MUST be HA2 — hard AWS requirement),
#   no gateway, default timers, config sync on.
#
# HA1 still needs TCP 28769+28260 AND ICMP between the firewalls' mgmt IPs
# (fw-mgmt security group) — the ICMP heartbeat is sent before the TCP link.
#
# Usage (all env, no secrets besides the SCM credentials sourced from your file):
#   PRIMARY_SERIAL  SECONDARY_SERIAL        numeric serials (from scm-onboard-fw.sh)
#   PRIMARY_MGMT_IP SECONDARY_MGMT_IP       mgmt IPs  (HA1 peer addresses)
#   PRIMARY_HA2_IP  SECONDARY_HA2_IP        HA2 ENI IPs (root output fw_ha2_private_ips)
#   [HA2_NETMASK=255.255.255.0] [GROUP_ID=1] [HA2_PORT=ethernet1/1]
#
# Run AFTER the folder config is pushed (the HA2 interface is created by this
# call, the dataplane interfaces by phase2-scm-config) and BEFORE relying on
# failover. Verify with: scripts/scm-verify.sh (ha_state / ha_peer_state).
###############################################################################
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scm-lib.sh
source "$HERE/scm-lib.sh"

: "${PRIMARY_SERIAL:?}" "${SECONDARY_SERIAL:?}"
: "${PRIMARY_MGMT_IP:?}" "${SECONDARY_MGMT_IP:?}"
: "${PRIMARY_HA2_IP:?}" "${SECONDARY_HA2_IP:?}"
HA2_NETMASK="${HA2_NETMASK:-255.255.255.0}"
HA2_PORT="${HA2_PORT:-ethernet1/1}"
GROUP_ID="${GROUP_ID:-1}"

for s in "$PRIMARY_SERIAL" "$SECONDARY_SERIAL"; do
  [[ "$s" =~ ^[0-9]+$ ]] || scm_die "serial '$s' is not numeric — the HA API takes the numeric device ID"
done

# ha_body DEVICE PEER_SERIAL PEER_MGMT_IP OWN_HA2_IP ROLE PRIORITY
ha_body() {
  jq -nc --arg dev "$1" --arg peer_s "$2" --arg peer_ip "$3" --arg ha2 "$4" \
         --arg role "$5" --arg prio "$6" --arg mask "$HA2_NETMASK" \
         --arg port "$HA2_PORT" --arg gid "$GROUP_ID" '
    { device: $dev, enabled: true,
      interface: { ha1: { port: "management" },
                   ha2: { port: $port, ip_address: $ha2, netmask: $mask } },
      group: { group_id: $gid, peer_ip: $peer_ip, peer_serial: $peer_s,
               configuration_synchronization: { enabled: true },
               mode: { active_passive: {} },
               election_option: { ha_role: $role, device_priority: $prio, preemptive: false } } }'
}

apply_ha() {
  local dev="$1" body="$2"
  if scm_api GET "/config/device/v1/ha-configurations?device=${dev}" >/dev/null 2>&1; then
    scm_log "device $dev already has an HA config -> updating"
    scm_api PUT "/config/device/v1/ha-configurations" "$body" >/dev/null
  else
    scm_log "device $dev has no HA config -> creating"
    scm_api POST "/config/device/v1/ha-configurations" "$body" >/dev/null
  fi
}

# Lower priority number = preferred active. Primary 100 / secondary 110, like path A.
apply_ha "$PRIMARY_SERIAL"   "$(ha_body "$PRIMARY_SERIAL"   "$SECONDARY_SERIAL" "$SECONDARY_MGMT_IP" "$PRIMARY_HA2_IP"   primary   100)"
apply_ha "$SECONDARY_SERIAL" "$(ha_body "$SECONDARY_SERIAL" "$PRIMARY_SERIAL"   "$PRIMARY_MGMT_IP"   "$SECONDARY_HA2_IP" secondary 110)"

scm_log "HA configs stored in SCM. Push them to the devices: scripts/scm-push.sh <folder>"
