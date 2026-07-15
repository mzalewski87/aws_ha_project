###############################################################################
# optional/eks-deploy/modules/eks_network
#
# Dedicated EKS spoke VPC. Nodes are private; all egress goes TGW -> security
# VPC -> VM-Series (inspected + EDL-controlled). Attaches to the existing TGW.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.name_prefix}-eks-vpc" })
}

resource "aws_subnet" "node" {
  for_each = { for i, az in var.azs : tostring(i) => { az = az, cidr = cidrsubnet(var.vpc_cidr, 4, i) } }

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags = merge(var.tags, {
    Name                              = "${var.name_prefix}-eks-node-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_subnet" "tgw" {
  for_each = { for i, az in var.azs : tostring(i) => { az = az, cidr = cidrsubnet(var.vpc_cidr, 8, 240 + i) } }

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags              = merge(var.tags, { Name = "${var.name_prefix}-eks-tgw-${each.key}" })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = [for s in aws_subnet.tgw : s.id]
  tags               = merge(var.tags, { Name = "${var.name_prefix}-eks-tgwattach" })
}

resource "aws_route_table" "node" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-eks-node-rt" })
}

# All node egress -> TGW -> FW (inspected). No IGW/NAT in the EKS VPC.
resource "aws_route" "node_default" {
  route_table_id         = aws_route_table.node.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route_table_association" "node" {
  for_each       = aws_subnet.node
  subnet_id      = each.value.id
  route_table_id = aws_route_table.node.id
}
