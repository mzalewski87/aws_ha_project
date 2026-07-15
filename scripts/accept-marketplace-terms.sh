#!/usr/bin/env bash
###############################################################################
# accept-marketplace-terms.sh
#
# AWS has NO CLI analog to `az vm image terms accept`: subscribing to the
# VM-Series / Panorama BYOL AMIs is a one-time, per-account, CONSOLE action.
#
# This script (a) prints the direct subscribe links, and (b) VERIFIES real
# subscription. NOTE: `describe-images` visibility is NOT a subscription proxy
# (marketplace AMIs are visible to everyone). The only reliable programmatic
# check is `run-instances --dry-run`: AWS returns OptInRequired when NOT
# subscribed, or DryRunOperation once terms are accepted.
#
# Env: AWS_REGION (default eu-central-1)
###############################################################################
set -euo pipefail
REGION="${AWS_REGION:-eu-central-1}"

VMSERIES_PC="6njl1pau431dv1qxipg63mvah"   # VM-Series BYOL product code
PANORAMA_PC="eclz7j04vu9lf8ont8ta3n17o"   # Panorama BYOL product code

cat <<EOF
AWS Marketplace subscription is console-only (one-time per account).
Open each link -> "Continue to Subscribe" -> "Accept Terms", then re-run this
script. Verifying REAL subscription (run-instances --dry-run) in ${REGION}:
  VM-Series (BYOL): https://aws.amazon.com/marketplace/pp?sku=${VMSERIES_PC}
  Panorama  (BYOL): https://aws.amazon.com/marketplace/pp?sku=${PANORAMA_PC}

EOF

# A subnet makes the "subscribed" path return DryRunOperation instead of a
# no-default-VPC error. Optional — OptInRequired is reported before any VPC check.
SUBNET="$(aws ec2 describe-subnets --region "${REGION}" \
  --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)"
SUBNET_ARG=()
[ -n "${SUBNET}" ] && [ "${SUBNET}" != "None" ] && SUBNET_ARG=(--subnet-id "${SUBNET}")

check() {
  local pc="$1" label="$2" itype="$3"
  local id out
  id="$(aws ec2 describe-images --region "${REGION}" --owners aws-marketplace \
    --filters "Name=product-code,Values=${pc}" \
    --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text 2>/dev/null || true)"
  if [ -z "${id}" ] || [ "${id}" = "None" ]; then
    echo "MISS ${label}: no AMI for product-code ${pc} in ${REGION}"
    return
  fi
  out="$(aws ec2 run-instances --dry-run --region "${REGION}" \
    --image-id "${id}" --instance-type "${itype}" "${SUBNET_ARG[@]}" 2>&1 || true)"
  if echo "${out}" | grep -q "OptInRequired"; then
    echo "MISS ${label}: NOT subscribed — accept terms: https://aws.amazon.com/marketplace/pp?sku=${pc}  (AMI ${id})"
  elif echo "${out}" | grep -q "DryRunOperation"; then
    echo "OK   ${label}: SUBSCRIBED — AMI ${id} launchable in ${REGION}"
  else
    # Not OptInRequired => subscription is fine; some other dry-run note (e.g. quota/VPC).
    echo "OK   ${label}: subscribed (AMI ${id}); dry-run note: $(echo "${out}" | tail -1)"
  fi
}
check "${VMSERIES_PC}" "VM-Series BYOL" "m5.xlarge"
check "${PANORAMA_PC}" "Panorama BYOL" "m5.4xlarge"
