###############################################################################
# modules/vpc — main
#
# One VPC with role-based subnets spread across AZs, optional IGW, optional
# per-AZ NAT Gateways, per-subnet route tables, and role-based security groups.
# Ports the Azure `networking` module's VNet+subnet+NSG concept (VNet->VPC,
# subnet->subnet, NSG->security group). VNet peering is NOT ported here — it
# becomes the Transit Gateway (modules/transit_gateway, ADR D5).
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

locals {
  # Flatten { role => {cidrs=[...]} } × AZs into per-(role, az) subnet instances.
  # Key format: "<role>-<az_index>" (e.g. "mgmt-0", "untrust-1").
  subnet_instances = merge([
    for role, cfg in var.subnets : {
      for i, az in var.azs : "${role}-${i}" => {
        role                    = role
        kind                    = cfg.kind
        az                      = az
        az_index                = i
        cidr                    = cfg.cidrs[i]
        map_public_ip_on_launch = cfg.map_public_ip_on_launch
      }
    }
  ]...)

  # The public subnet instance in each AZ hosts that AZ's NAT Gateway.
  public_subnet_by_az = {
    for k, s in local.subnet_instances : s.az_index => k if s.kind == "public"
  }
}

###############################################################################
# VPC
###############################################################################
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

###############################################################################
# Subnets
###############################################################################
resource "aws_subnet" "this" {
  for_each = local.subnet_instances

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = each.value.map_public_ip_on_launch
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}

###############################################################################
# Internet Gateway (only when the VPC has public subnets)
###############################################################################
resource "aws_internet_gateway" "this" {
  count  = var.create_igw ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

###############################################################################
# NAT Gateways — one per AZ, in that AZ's public subnet (ADR: per-AZ egress HA)
###############################################################################
resource "aws_eip" "nat" {
  for_each = var.create_nat ? local.public_subnet_by_az : {}
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "${var.name_prefix}-nat-eip-az${each.key}" })
}

resource "aws_nat_gateway" "this" {
  for_each = var.create_nat ? local.public_subnet_by_az : {}

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.this[each.value].id
  tags          = merge(var.tags, { Name = "${var.name_prefix}-nat-az${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Route tables — one per subnet instance (per-AZ, because NAT differs per AZ)
###############################################################################
resource "aws_route_table" "this" {
  for_each = local.subnet_instances
  vpc_id   = aws_vpc.this.id
  tags     = merge(var.tags, { Name = "${var.name_prefix}-${each.key}-rt" })
}

resource "aws_route_table_association" "this" {
  for_each       = local.subnet_instances
  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.this[each.key].id
}

# public subnets -> Internet Gateway
resource "aws_route" "public_default" {
  for_each = { for k, s in local.subnet_instances : k => s if s.kind == "public" && var.create_igw }

  route_table_id         = aws_route_table.this[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

# private subnets -> NAT Gateway in the same AZ
resource "aws_route" "private_default" {
  for_each = { for k, s in local.subnet_instances : k => s if s.kind == "private" && var.create_nat }

  route_table_id         = aws_route_table.this[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.value.az_index].id
}

# NOTE: "isolated" subnets (trust / ha2 / tgw-attach / spoke workloads) get a
# route table with local routes only. Their TGW / dataplane routes are added by
# modules/transit_gateway (mgmt<->security) and the Phase 1b routing module
# (spoke default -> FW), once those next-hops exist.

###############################################################################
# Security Groups (role-based; consumed by instances in later phases)
###############################################################################
resource "aws_security_group" "this" {
  for_each = var.security_groups

  name        = "${var.name_prefix}-${each.key}"
  description = each.value.description
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })

  dynamic "ingress" {
    for_each = each.value.ingress
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  # Default to allow-all egress when the caller omits egress. A bare
  # aws_security_group with no egress block drops AWS's implicit allow-all,
  # which silently blocks ALL outbound (e.g. FW mgmt can't reach PANW licensing
  # / device-cert servers -> "Failed to get license info" -> no Panorama
  # registration). Restore the AWS default unless egress is explicitly given.
  dynamic "egress" {
    for_each = length(each.value.egress) > 0 ? each.value.egress : [
      { description = "default allow all", from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }
    ]
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }
}
