###############################################################################
# Cross-region TGW peering (Phase R2) — lets Region B FWs reach the single
# Region A Panorama (ADR D6) over the private backbone (no public Panorama, D8).
#
# Management-plane path:
#   Region B FW mgmt (security VPC 10.20/16) -> Region B TGW (security RT)
#     -> peering -> Region A TGW (security RT) -> Panorama (mgmt VPC 10.11/16)
#   return: Panorama -> Region A TGW (spoke RT) -> peering -> Region B (security RT)
#
# All gated by var.enable_region_b.
###############################################################################

resource "aws_ec2_transit_gateway_peering_attachment" "ab" {
  count = var.enable_region_b ? 1 : 0

  transit_gateway_id      = module.region_a.transit_gateway_id
  peer_transit_gateway_id = module.region_b[0].transit_gateway_id
  peer_region             = var.region_b
  tags                    = { Name = "${var.name_prefix}-tgw-peer-ab" }
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "ab" {
  count    = var.enable_region_b ? 1 : 0
  provider = aws.region_b

  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.ab[0].id
  tags                          = { Name = "${var.name_prefix}-tgw-peer-ab-accepter" }
}

# Associate the peering attachment with each region's security route table.
resource "aws_ec2_transit_gateway_route_table_association" "peer_a" {
  count = var.enable_region_b ? 1 : 0

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.ab[0].id
  transit_gateway_route_table_id = module.region_a.tgw_security_route_table_id
}

resource "aws_ec2_transit_gateway_route_table_association" "peer_b" {
  count    = var.enable_region_b ? 1 : 0
  provider = aws.region_b

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment_accepter.ab[0].transit_gateway_attachment_id
  transit_gateway_route_table_id = module.region_b[0].tgw_security_route_table_id
}

# TGW routes toward the peer.
# Region A: Panorama (mgmt VPC, spoke RT) egresses to Region B security VPC.
resource "aws_ec2_transit_gateway_route" "a_to_b" {
  count = var.enable_region_b ? 1 : 0

  transit_gateway_route_table_id = module.region_a.tgw_spoke_route_table_id
  destination_cidr_block         = var.security_vpc_cidr_b
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.ab[0].id
}

# Region B: FW mgmt (security RT) egresses to Region A mgmt VPC (Panorama); and
# deliver inbound Panorama replies to the local security VPC.
resource "aws_ec2_transit_gateway_route" "b_to_a" {
  count    = var.enable_region_b ? 1 : 0
  provider = aws.region_b

  transit_gateway_route_table_id = module.region_b[0].tgw_security_route_table_id
  destination_cidr_block         = var.mgmt_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment_accepter.ab[0].transit_gateway_attachment_id
}

resource "aws_ec2_transit_gateway_route" "b_local_security" {
  count    = var.enable_region_b ? 1 : 0
  provider = aws.region_b

  transit_gateway_route_table_id = module.region_b[0].tgw_security_route_table_id
  destination_cidr_block         = var.security_vpc_cidr_b
  transit_gateway_attachment_id  = module.region_b[0].tgw_security_attachment_id
}

# VPC subnet routes toward the TGW for the cross-region mgmt path.
# Region A Panorama subnets -> Region B security VPC via Region A TGW.
resource "aws_route" "a_panorama_to_b" {
  for_each = var.enable_region_b ? toset(module.region_a.mgmt_panorama_route_table_ids) : toset([])

  route_table_id         = each.value
  destination_cidr_block = var.security_vpc_cidr_b
  transit_gateway_id     = module.region_a.transit_gateway_id
}

# Region A SSM jump-host subnets -> Region B security VPC via Region A TGW.
# The jump host (mgmt VPC ssm subnet) SSHes to Region B firewall mgmt IPs to push
# native HA config (scripts/configure-ha.sh). Without this route its subnet has no
# path to 10.20/16 and the HA push to Region B silently times out (the
# a_panorama_to_b route only covers the panorama subnet, not the ssm subnet).
resource "aws_route" "a_ssm_to_b" {
  for_each = var.enable_region_b ? toset(module.region_a.mgmt_ssm_route_table_ids) : toset([])

  route_table_id         = each.value
  destination_cidr_block = var.security_vpc_cidr_b
  transit_gateway_id     = module.region_a.transit_gateway_id
}

# Each region's FIREWALL-mgmt subnet -> the OTHER region's spoke2 (DC) CIDR, so a
# firewall can query the REMOTE DC for GP LDAP. The GP LDAP profile lists both
# DCs; PAN-OS tries them in list order, so a firewall that can only reach its
# local DC stalls on the remote one first and GP login times out. The TGW
# security RTs already carry the
# peer-spoke CIDR via peering (a_sec_to_b_dc / b_sec_to_a_dc below); this adds
# the missing VPC-level route on the FW-mgmt subnets. Region-local DC still wins
# on a region outage (the remote one is then down and LDAP fails over).
resource "aws_route" "a_fwmgmt_to_b_dc" {
  for_each = var.enable_region_b ? toset(module.region_a.security_mgmt_route_table_ids) : toset([])

  route_table_id         = each.value
  destination_cidr_block = var.spoke2_vpc_cidr_b
  transit_gateway_id     = module.region_a.transit_gateway_id
}

resource "aws_route" "b_fwmgmt_to_a_dc" {
  for_each = var.enable_region_b ? toset(module.region_b[0].security_mgmt_route_table_ids) : toset([])
  provider = aws.region_b

  route_table_id         = each.value
  destination_cidr_block = var.spoke2_vpc_cidr
  transit_gateway_id     = module.region_b[0].transit_gateway_id
}

# --- Cross-region spoke2 (AD DC) reachability -------------------------------
# So the Region A DC (spoke2 VPC, 10.13/16) and a Region B DC (10.23/16) can
# reach each other for domain-join + AD replication, AND so each region's
# firewalls can query BOTH DCs for GP LDAP (resilient auth on a region outage).
#
# Only TGW routes are needed — no VPC routes: spoke2 workload subnets already
# default 0/0 -> TGW, and the delivery routes (security RT -> local spoke2
# attachment) already exist from the TGW module's security_to_spokes. The
# peer-spoke CIDR must be reachable via peering from BOTH the spoke RT (DC
# workload, spoke-RT-associated) and the security RT (firewall LDAP,
# security-RT-associated). DC<->DC traffic rides TGW-to-TGW (not the FW
# dataplane), same as the Panorama mgmt path.
resource "aws_ec2_transit_gateway_route" "a_spoke_to_b_dc" {
  count                          = var.enable_region_b ? 1 : 0
  transit_gateway_route_table_id = module.region_a.tgw_spoke_route_table_id
  destination_cidr_block         = var.spoke2_vpc_cidr_b
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.ab[0].id
}

resource "aws_ec2_transit_gateway_route" "a_sec_to_b_dc" {
  count                          = var.enable_region_b ? 1 : 0
  transit_gateway_route_table_id = module.region_a.tgw_security_route_table_id
  destination_cidr_block         = var.spoke2_vpc_cidr_b
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.ab[0].id
}

resource "aws_ec2_transit_gateway_route" "b_spoke_to_a_dc" {
  count                          = var.enable_region_b ? 1 : 0
  provider                       = aws.region_b
  transit_gateway_route_table_id = module.region_b[0].tgw_spoke_route_table_id
  destination_cidr_block         = var.spoke2_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment_accepter.ab[0].transit_gateway_attachment_id
}

resource "aws_ec2_transit_gateway_route" "b_sec_to_a_dc" {
  count                          = var.enable_region_b ? 1 : 0
  provider                       = aws.region_b
  transit_gateway_route_table_id = module.region_b[0].tgw_security_route_table_id
  destination_cidr_block         = var.spoke2_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment_accepter.ab[0].transit_gateway_attachment_id
}

# Region B FW mgmt subnets -> Region A mgmt VPC (Panorama) via Region B TGW.
resource "aws_route" "b_fwmgmt_to_a" {
  for_each = var.enable_region_b ? toset(module.region_b[0].security_mgmt_route_table_ids) : toset([])
  provider = aws.region_b

  route_table_id         = each.value
  destination_cidr_block = var.mgmt_vpc_cidr
  transit_gateway_id     = module.region_b[0].transit_gateway_id
}
