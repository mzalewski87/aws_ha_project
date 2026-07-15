###############################################################################
# Phase 2a — Panorama configuration via the panos provider (v2).
#
# The panos provider connects to Panorama on EVERY plan, so it lives in this
# separate workspace (same load-bearing split as Azure). Panorama has no public
# IP and PAN-OS runs no SSM agent, so reachability is an SSM port-forward through
# the jump host (module.panorama), mapping localhost:44300 -> Panorama:443:
#
#   PANORAMA_ID=$(cd .. && terraform output -raw ssm_jumphost_instance_id)
#   PANORAMA_IP=$(cd .. && terraform output -raw panorama_private_ip)
#   aws ssm start-session --target "$PANORAMA_ID" \
#     --document-name AWS-StartPortForwardingSessionToRemoteHost \
#     --parameters "{\"host\":[\"$PANORAMA_IP\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"44300\"]}"
#
# See scripts/configure-panorama.sh.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    panos = {
      source  = "PaloAltoNetworks/panos"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "panos" {
  hostname                = var.panorama_hostname
  port                    = var.panorama_port
  username                = var.panorama_username
  password                = var.panorama_password
  skip_verify_certificate = true
}
