###############################################################################
# modules/routing — main
#
# Ports the Azure routing module (spoke UDR -> internal LB) to the AWS
# TGW-centric model. Depends on the firewall + transit_gateway + vpc modules.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

# TGW inspection ingress: traffic arriving from the TGW into the security VPC is
# sent to the active FW trust ENI for inspection. HA plugin ReplaceRoute updates
# this to the peer on failover.
# The route below is runtime-owned (ignore_changes), so Terraform would never repair it if the
# firewalls were recreated and the ENI it points at disappeared. Tie it to the ENI id: a new
# initial-active trust ENI replaces the route.
resource "terraform_data" "active_trust_eni" {
  input = var.active_trust_eni_id
}

resource "aws_route" "tgwattach_to_fw" {
  for_each = var.security_tgw_attach_route_table_ids

  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = var.active_trust_eni_id

  # Runtime-owned after the first failover: the PAN-OS AWS HA plugin repoints this route at
  # the active unit's trust ENI (ReplaceRoute). Terraform must not put it back on fw1, or it
  # black-holes all spoke/east-west traffic whenever fw2 is active.
  lifecycle {
    ignore_changes       = [network_interface_id]
    replace_triggered_by = [terraform_data.active_trust_eni]
  }
}

# FW return path: the trust ENI sends spoke/mgmt-bound traffic back to the TGW.
resource "aws_route" "trust_to_tgw" {
  for_each = var.security_trust_route_table_ids

  route_table_id         = each.value
  destination_cidr_block = var.inspected_supernet
  transit_gateway_id     = var.transit_gateway_id
}

# Spoke internet + east-west inspection: default route on the TGW spoke RT points
# at the security attachment. Now live (the FW dataplane exists).
resource "aws_ec2_transit_gateway_route" "spoke_default_to_security" {
  transit_gateway_route_table_id = var.tgw_spoke_route_table_id
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = var.tgw_security_attachment_id
}

# Spoke workload subnets send everything to the TGW (then to the FW).
resource "aws_route" "spoke_default_to_tgw" {
  for_each = var.spoke_workload_route_table_ids

  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id
}
