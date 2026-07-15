#!/usr/bin/env bash
###############################################################################
# configure-ha.sh — Phase 1b/HA helper (run once per firewall, after both
# firewalls are registered with Panorama and phase2-panorama-config's
# ethernet1/1 (ha2)/ethernet1/3 (untrust) interface config has been pushed).
#
# WHY a script instead of the panos Terraform provider: the panos provider
# (v2) has NO resources for native PAN-OS HA (Setup/Election/Control-Link/
# Data-Link) — confirmed via `terraform providers schema -json`, zero
# panos_ha_* resources and no HA block in panos_general_settings. HA general
# config is also device-local (different peer-ip/priority per firewall), not
# something Panorama's shared template/device-group push can express. So this
# talks directly to each firewalls own mgmt IP, the same SSH pattern as
# set-panorama-password.sh, rather than going through the panos provider.
#
# Load-bearing details:
#   - ethernet1/1 MUST be the HA2 link (AWS platform requirement, not just an
#     example in PANW's docs) — phase2-panorama-config must already have
#     configured this (panos_ethernet_interface "ha2") before running this.
#   - HA1 (control link) runs over the management interface; requires TCP
#     28769 + 28260 open between the firewalls' mgmt IPs (fw-mgmt SG).
#   - The HA1 heartbeat itself is an ICMP echo, sent BEFORE the TCP link is
#     attempted ("waiting for ping response before starting connection" in
#     mp-log ha_agent.log) — ICMP between the mgmt IPs must also be open.
#   - Preemption is intentionally left off (PANW's own guidance: "Preemption
#     is not recommended for HA in the VM-Series firewall on AWS").
#
# Inputs (env):
#   JUMP (jump-host instance id), FW_IP (this firewalls mgmt IP), KEY_FILE,
#   PEER_IP (the OTHER firewalls mgmt IP), DEVICE_PRIORITY (lower = preferred
#   active), HA2_IP, HA2_NETMASK (default 255.255.255.0), GROUP_ID (default 1)
###############################################################################
set -euo pipefail

: "${JUMP:?JUMP (jump-host instance id) required}"
: "${FW_IP:?FW_IP (this firewalls mgmt IP) required}"
: "${PEER_IP:?PEER_IP (the other firewalls mgmt IP) required}"
: "${DEVICE_PRIORITY:?DEVICE_PRIORITY required (e.g. 100 for the preferred-active firewall, 110 for its peer)}"
: "${HA2_IP:?HA2_IP required (this firewalls ha2 ENI private IP)}"
KEY_FILE="${KEY_FILE:?KEY_FILE (SSH private key path) required}"
HA2_NETMASK="${HA2_NETMASK:-255.255.255.0}"
GROUP_ID="${GROUP_ID:-1}"
FW_USER="${FW_USER:-admin}"
# Local forward port is derived from the firewall's mgmt IP last octet so that
# running this back-to-back for fw1 then fw2 uses DIFFERENT ports. With a fixed
# port, a not-yet-torn-down SSM tunnel from the first run stays bound and the
# second run's SSH silently reaches the FIRST firewall — which pushed fw2's
# config (peer-ip = its own IP) onto fw1 and left fw2 untouched ("HA not
# enabled"). Unique port per FW avoids that collision entirely.
LP="${SSH_LOCAL_PORT:-23${FW_IP##*.}}"
export AWS_REGION="${AWS_REGION:-eu-central-1}"

KEY_FILE="${KEY_FILE/#\~/$HOME}"
if [ ! -f "${KEY_FILE}" ]; then
  echo "[configure-ha] ERROR: SSH private key not found: ${KEY_FILE}" >&2
  exit 1
fi
for bin in aws ssh session-manager-plugin; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[configure-ha] ERROR: '$bin' not found in PATH" >&2; exit 1; }
done

# NOTE: no -tt here. The readiness probe below runs `ssh ... 'exit'`; with a
# forced pty (-tt) PAN-OS opens its interactive CLI, ignores the exec command,
# and the ssh call hangs forever (the probe never returns, so "waiting for SSH"
# loops until timeout even though SSH is up). The config push adds -tt inline,
# because THAT one needs an interactive pty to feed the here-doc — same split as
# set-panorama-password.sh.
SSH_OPTS=(-i "${KEY_FILE}" -p "${LP}"
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR
  -o ConnectTimeout=10 -o PreferredAuthentications=publickey)

SSM_PID=""
cleanup() { kill "${SSM_PID}" 2>/dev/null || true; }
trap cleanup EXIT

echo "[configure-ha] opening SSM tunnel ${JUMP} -> ${FW_IP}:22 (local ${LP})"
aws ssm start-session --target "${JUMP}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${FW_IP}\"],\"portNumber\":[\"22\"],\"localPortNumber\":[\"${LP}\"]}" \
  >"/tmp/ssm-ha.$$.log" 2>&1 &
SSM_PID=$!

echo "[configure-ha] waiting for SSH..."
ready=0
for _ in $(seq 1 30); do
  if ssh "${SSH_OPTS[@]}" "${FW_USER}@127.0.0.1" 'exit' >/dev/null 2>&1; then ready=1; break; fi
  sleep 5
done
if [ "${ready}" -ne 1 ]; then
  echo "[configure-ha] ERROR: SSH to ${FW_IP} never became ready. Tunnel log:" >&2
  tail -n 20 "/tmp/ssm-ha.$$.log" >&2 || true
  exit 1
fi

echo "[configure-ha] pushing HA config (group ${GROUP_ID}, priority ${DEVICE_PRIORITY}, peer ${PEER_IP})"
ssh -tt "${SSH_OPTS[@]}" "${FW_USER}@127.0.0.1" >"/tmp/ssm-ha-set.$$.log" 2>&1 <<EOF || true
set cli pager off
configure
set deviceconfig high-availability enabled yes
set deviceconfig high-availability group group-id ${GROUP_ID}
set deviceconfig high-availability group mode active-passive
set deviceconfig high-availability group election-option device-priority ${DEVICE_PRIORITY}
set deviceconfig high-availability group election-option preemptive no
set deviceconfig high-availability group peer-ip ${PEER_IP}
set deviceconfig high-availability interface ha1 port management
set deviceconfig high-availability interface ha2 port ethernet1/1
set deviceconfig high-availability interface ha2 ip-address ${HA2_IP}
set deviceconfig high-availability interface ha2 netmask ${HA2_NETMASK}
commit description "configure-ha.sh: enable native HA (active-passive)"
exit
exit
EOF

echo "[configure-ha] done. Verify on both firewalls: show high-availability state"
echo "                (expect Connection status: up, one active / one passive, Running Configuration: synchronized)"
