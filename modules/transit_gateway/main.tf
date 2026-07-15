###############################################################################
# modules/transit_gateway — main
#
# TGW + VPC attachments + two route tables (security / spoke) forcing spoke and
# management traffic through the security VPC. Default association/propagation on
# the TGW is disabled so associations are explicit and auditable.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

locals {
  security_key = one([for k, a in var.attachments : k if a.associate_with == "security"])
  spoke_keys   = [for k, a in var.attachments : k if a.associate_with == "spoke"]
}

resource "aws_ec2_transit_gateway" "this" {
  description                     = "${var.name_prefix} transit gateway (centralized inspection hub)"
  amazon_side_asn                 = var.amazon_side_asn
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  tags                            = merge(var.tags, { Name = "${var.name_prefix}-tgw" })
}

###############################################################################
# VPC attachments
# appliance_mode_support = enable ONLY on the security VPC — mandatory for
# cross-AZ flow symmetry through the stateful firewalls (ADR D5 / briefing §2).
###############################################################################
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  for_each = var.attachments

  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  vpc_id                 = each.value.vpc_id
  subnet_ids             = each.value.subnet_ids
  appliance_mode_support = each.value.associate_with == "security" ? "enable" : "disable"

  # Manage associations/propagations explicitly via the route tables below.
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.tags, { Name = "${var.name_prefix}-tgwattach-${each.key}" })
}

###############################################################################
# TGW route tables
###############################################################################
resource "aws_ec2_transit_gateway_route_table" "security" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.name_prefix}-tgw-rt-security" })
}

resource "aws_ec2_transit_gateway_route_table" "spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.name_prefix}-tgw-rt-spoke" })
}

# Associations: security attachment -> security RT; all others -> spoke RT.
resource "aws_ec2_transit_gateway_route_table_association" "security" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.security_key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security.id
}

resource "aws_ec2_transit_gateway_route_table_association" "spoke" {
  for_each                       = toset(local.spoke_keys)
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke.id
}

###############################################################################
# Security RT: reach every spoke/mgmt VPC directly (FW return path to each VPC).
###############################################################################
resource "aws_ec2_transit_gateway_route" "security_to_spokes" {
  for_each = { for k in local.spoke_keys : k => var.attachments[k] }

  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security.id
  destination_cidr_block         = each.value.vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
}

###############################################################################
# Spoke RT: send traffic destined to the security VPC (FW mgmt subnet) and to
# other spoke VPCs to the security attachment. The security-VPC CIDR route makes
# the Panorama <-> FW-mgmt path work; inter-spoke routes force east-west through
# the FWs. A default 0.0.0.0/0 -> security (spoke internet inspection) becomes
# live in Phase 1b once the FW dataplane exists — added there, not here.
###############################################################################
resource "aws_ec2_transit_gateway_route" "spoke_to_security_cidr" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke.id
  destination_cidr_block         = var.attachments[local.security_key].vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.security_key].id
}

resource "aws_ec2_transit_gateway_route" "spoke_to_spoke" {
  for_each = { for k in local.spoke_keys : k => var.attachments[k] }

  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke.id
  destination_cidr_block         = each.value.vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.security_key].id
}

###############################################################################
# Routes inside VPC route tables pointing at the TGW (management-plane path).
###############################################################################
resource "aws_route" "to_tgw" {
  # Keyed by static ids from the caller (route_table_id is unknown at plan).
  for_each = var.tgw_routes_in_vpc

  route_table_id         = each.value.route_table_id
  destination_cidr_block = each.value.destination_cidr_block
  transit_gateway_id     = aws_ec2_transit_gateway.this.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}
