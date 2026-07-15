#!/usr/bin/env bash
###############################################################################
# failover-test.sh — on/off resilience test harness (HA + region failure)
#
# Two scenarios, each with a `down` (induce failure) and `up` (restore) action,
# plus `status`. Uses only the AWS API (EC2 stop/start + describe) — no SSH / no
# jump host — so it works for BOTH regions and simulates a REAL failure (the
# firewall/region going away), which is what the PAN-OS AWS HA plugin, AWS
# Global Accelerator, and GlobalProtect-native gateway failover are meant to
# survive.
#
# USAGE:
#   AWS_PROFILE=awsha bash scripts/failover-test.sh status  <a|b>
#   AWS_PROFILE=awsha bash scripts/failover-test.sh ha      <a|b> down|up
#   AWS_PROFILE=awsha bash scripts/failover-test.sh region  <a|b> down|up
#
# SCENARIOS
#   ha <region> down : stop the ACTIVE firewall in that region. Expected: the
#       peer takes over — the untrust floating IP (+ its Elastic IP) and the
#       TGW inspection default route move to the peer (PAN-OS AWS HA plugin).
#       Verify with `... status <region>` (active flips; EIP/route on the peer).
#   ha <region> up   : start the stopped firewall; it rejoins as passive
#       (preemption is off by design), no flap.
#   region <region> down : stop BOTH firewalls in that region -> the regional GP
#       portal/gateway go dark. Expected: Global Accelerator health checks (TCP
#       443) drop that region's endpoint within ~30s and steer the anycast portal
#       traffic to the healthy region; GP agents fail over to the other region's
#       gateway (GP-native best-available). Verify GA endpoint health + that the
#       portal still answers on the GA anycast IPs.
#   region <region> up   : start both firewalls; the region rejoins GA once
#       health checks pass again.
#
# Region tag: "a" -> ${NAME_PREFIX}-a-*, "b" -> ${NAME_PREFIX}-b-*.
###############################################################################
set -euo pipefail

NAME_PREFIX="${NAME_PREFIX:-awsha}"
REGION_A="${REGION_A:-eu-central-1}"
REGION_B="${REGION_B:-eu-west-1}"
FLOATING_A="${FLOATING_A:-10.10.10.100}"
FLOATING_B="${FLOATING_B:-10.20.10.100}"

action="${1:-status}"; rtag="${2:-a}"; sub="${3:-}"

case "${rtag}" in
  a) region="${REGION_A}"; floating="${FLOATING_A}" ;;
  b) region="${REGION_B}"; floating="${FLOATING_B}" ;;
  *) echo "region tag must be a|b" >&2; exit 1 ;;
esac
export AWS_REGION="${region}"

fw_id() {  # $1 = fw1|fw2 -> instance id
  aws ec2 describe-instances --region "${region}" \
    --filters "Name=tag:Name,Values=${NAME_PREFIX}-${rtag}-$1" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId | [0]' --output text
}

active_fw() {  # prints fw1/fw2 that currently owns the floating IP (= active)
  local eni
  eni="$(aws ec2 describe-network-interfaces --region "${region}" \
    --filters "Name=addresses.private-ip-address,Values=${floating}" \
    --query 'NetworkInterfaces[0].TagSet[?Key==`Name`]|[0].Value' --output text 2>/dev/null)"
  case "${eni}" in
    *fw1*) echo fw1 ;; *fw2*) echo fw2 ;; *) echo "unknown" ;;
  esac
}

show_status() {
  echo "== Region ${rtag} (${region}) status =="
  for fw in fw1 fw2; do
    local id st
    id="$(fw_id "${fw}")"
    st="$(aws ec2 describe-instances --region "${region}" --instance-ids "${id}" \
          --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo '?')"
    echo "  ${fw}: ${id} (${st})"
  done
  echo "  floating ${floating} / public EIP is on: $(active_fw)  <- current ACTIVE"
  aws ec2 describe-addresses --region "${region}" \
    --filters "Name=private-ip-address,Values=${floating}" \
    --query 'Addresses[0].[PublicIp,PrivateIpAddress]' --output text 2>/dev/null \
    | sed 's/^/  EIP mapping: /' || true
  # GA endpoint health (global control plane in us-west-2)
  local acc
  acc="$(aws globalaccelerator list-accelerators --region us-west-2 \
        --query "Accelerators[?contains(Name, '${NAME_PREFIX}')].AcceleratorArn | [0]" --output text 2>/dev/null || true)"
  if [ -n "${acc}" ] && [ "${acc}" != "None" ]; then
    echo "  Global Accelerator: ${acc}"
    aws globalaccelerator describe-accelerator --region us-west-2 --accelerator-arn "${acc}" \
      --query 'Accelerator.IpSets[0].IpAddresses' --output text 2>/dev/null | sed 's/^/  GA anycast IPs: /' || true
  fi
}

ha_down() {
  local a; a="$(active_fw)"
  [ "${a}" = "unknown" ] && { echo "cannot determine active FW (floating ${floating} not found)"; exit 1; }
  local id; id="$(fw_id "${a}")"
  echo "[ha down] stopping ACTIVE ${a} (${id}) in region ${rtag} to force HA failover..."
  aws ec2 stop-instances --region "${region}" --instance-ids "${id}" --query 'StoppingInstances[0].CurrentState.Name' --output text
  echo "[ha down] wait ~30-60s, then: bash scripts/failover-test.sh status ${rtag}  (expect active flipped to the peer; EIP/route moved)"
}

ha_up() {
  local stopped
  stopped="$(aws ec2 describe-instances --region "${region}" \
    --filters "Name=tag:Name,Values=${NAME_PREFIX}-${rtag}-fw*" "Name=instance-state-name,Values=stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  [ -z "${stopped}" ] && { echo "[ha up] no stopped firewall in region ${rtag}"; exit 0; }
  echo "[ha up] starting ${stopped} (rejoins as passive; preemption is off)"
  aws ec2 start-instances --region "${region}" --instance-ids ${stopped} --query 'StartingInstances[].CurrentState.Name' --output text
}

region_down() {
  local ids; ids="$(fw_id fw1) $(fw_id fw2)"
  echo "[region down] stopping BOTH firewalls in region ${rtag} (${ids}) to simulate a region outage..."
  aws ec2 stop-instances --region "${region}" --instance-ids ${ids} --query 'StoppingInstances[].CurrentState.Name' --output text
  echo "[region down] GA health checks should drop region ${rtag} within ~30s; portal stays up via the other region. GP agents fail over (native)."
}

region_up() {
  local ids; ids="$(fw_id fw1) $(fw_id fw2)"
  echo "[region up] starting both firewalls in region ${rtag} (${ids})"
  aws ec2 start-instances --region "${region}" --instance-ids ${ids} --query 'StartingInstances[].CurrentState.Name' --output text
}

case "${action}:${sub}" in
  status:*)     show_status ;;
  ha:down)      ha_down ;;
  ha:up)        ha_up ;;
  region:down)  region_down ;;
  region:up)    region_up ;;
  *) echo "usage: $0 status <a|b> | ha <a|b> down|up | region <a|b> down|up" >&2; exit 1 ;;
esac
