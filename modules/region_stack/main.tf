###############################################################################
# modules/region_stack — main
#
# One regional stack. Uses the calling module's default aws provider, so root
# selects the region by passing providers = { aws = aws.region_b } for Region B.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

# EC2 key pairs are region-local: a multi-region deploy needs the same-named key
# created in EACH region, or Region B fails with "key pair does not exist". When
# ssh_public_key is supplied, create it here so no manual per-region import is
# needed; otherwise assume key_name already exists in this region.
resource "aws_key_pair" "this" {
  count      = var.ssh_public_key != "" && var.key_name != null ? 1 : 0
  key_name   = var.key_name
  public_key = var.ssh_public_key
  tags       = merge(var.tags, { Name = var.key_name })
}

locals {
  sec = var.security_vpc_cidr
  mg  = var.mgmt_vpc_cidr
  s1  = var.spoke1_vpc_cidr
  s2  = var.spoke2_vpc_cidr

  # Use the created key pair's name when we made one (so instances depend on it),
  # else the caller-supplied pre-existing name.
  key_name = length(aws_key_pair.this) > 0 ? aws_key_pair.this[0].key_name : var.key_name

  # /24 subnets derived from each /16 (index = 3rd octet).
  security_subnets = {
    mgmt    = { kind = "private", cidrs = [cidrsubnet(local.sec, 8, 0), cidrsubnet(local.sec, 8, 1)] }
    untrust = { kind = "public", cidrs = [cidrsubnet(local.sec, 8, 10), cidrsubnet(local.sec, 8, 11)] }
    trust   = { kind = "isolated", cidrs = [cidrsubnet(local.sec, 8, 20), cidrsubnet(local.sec, 8, 21)] }
    ha2     = { kind = "isolated", cidrs = [cidrsubnet(local.sec, 8, 30), cidrsubnet(local.sec, 8, 31)] }
    tgw     = { kind = "isolated", cidrs = [cidrsubnet(local.sec, 8, 40), cidrsubnet(local.sec, 8, 41)] }
  }
  mgmt_subnets = {
    panorama = { kind = "private", cidrs = [cidrsubnet(local.mg, 8, 0), cidrsubnet(local.mg, 8, 1)] }
    ssm      = { kind = "private", cidrs = [cidrsubnet(local.mg, 8, 10), cidrsubnet(local.mg, 8, 11)] }
    public   = { kind = "public", cidrs = [cidrsubnet(local.mg, 8, 250), cidrsubnet(local.mg, 8, 251)] }
    tgw      = { kind = "isolated", cidrs = [cidrsubnet(local.mg, 8, 40), cidrsubnet(local.mg, 8, 41)] }
  }
  spoke1_subnets = {
    workload = { kind = "isolated", cidrs = [cidrsubnet(local.s1, 8, 0), cidrsubnet(local.s1, 8, 1)] }
    tgw      = { kind = "isolated", cidrs = [cidrsubnet(local.s1, 8, 40), cidrsubnet(local.s1, 8, 41)] }
  }
  spoke2_subnets = {
    workload = { kind = "isolated", cidrs = [cidrsubnet(local.s2, 8, 0), cidrsubnet(local.s2, 8, 1)] }
    tgw      = { kind = "isolated", cidrs = [cidrsubnet(local.s2, 8, 40), cidrsubnet(local.s2, 8, 41)] }
  }

  fw_security_groups = {
    fw-mgmt = {
      description = "FW eth0 management + PAN-OS control plane"
      # var.remote_panorama_cidr is the mgmt VPC CIDR of the region that HOSTS
      # Panorama — needed on the SECONDARY region's firewalls so the shared
      # Panorama (reached over cross-region TGW peering) can open the PAN-OS
      # control-plane connection back to them. Empty ("") on the primary region
      # (Panorama is local, covered by local.mg). WITHOUT this, secondary-region
      # firewalls never register (they stay Connected=no; the SG only allows the
      # local mgmt CIDR, not the remote Panorama's 10.11/16).
      ingress = [
        { description = "SSH", from_port = 22, to_port = 22, protocol = "tcp", cidr_blocks = compact([local.mg, local.sec, var.remote_panorama_cidr]) },
        { description = "HTTPS", from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = compact([local.mg, local.sec, var.remote_panorama_cidr]) },
        { description = "PAN-OS 3978", from_port = 3978, to_port = 3978, protocol = "tcp", cidr_blocks = compact([local.mg, local.sec, var.remote_panorama_cidr]) },
        { description = "PAN-OS 28443", from_port = 28443, to_port = 28443, protocol = "tcp", cidr_blocks = compact([local.mg, local.sec, var.remote_panorama_cidr]) },
        # HA1 control link (heartbeats + config sync) runs over mgmt on AWS
        # (VM-Series Deployment Guide, "HA Links"): TCP 28769 + 28260
        # cleartext, or TCP 28 if HA1 encryption is enabled (not used here).
        # Without these ports, HA peers stay "Connection status: down / Never
        # able to connect to peer".
        { description = "HA1 control link", from_port = 28769, to_port = 28769, protocol = "tcp", cidr_blocks = [local.sec] },
        { description = "HA1 control link (legacy)", from_port = 28260, to_port = 28260, protocol = "tcp", cidr_blocks = [local.sec] },
        # The HA1 heartbeat itself is an ICMP echo ("ha_agent.log": "waiting
        # for ping response before starting connection" / "no primary link"
        # until the peer answers) -- the TCP ports above are only opened
        # AFTER this ping succeeds, so ICMP must be open too or the connection
        # never comes up.
        { description = "HA1 ICMP heartbeat", from_port = -1, to_port = -1, protocol = "icmp", cidr_blocks = [local.sec] },
      ]
    }
    fw-untrust = {
      description = "FW eth1/1 untrust - FW inspects, SG permissive"
      ingress     = [{ description = "All (FW enforces policy; incl. GP TCP 443 / UDP 4501)", from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }]
    }
    fw-trust = {
      description = "FW eth1/2 trust - internal only"
      ingress     = [{ description = "All internal", from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["10.0.0.0/8"] }]
    }
    fw-ha2 = {
      description = "FW HA2 state sync between peers"
      ingress     = [{ description = "HA2 within security VPC", from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = [local.sec] }]
    }
  }
}

# --- VPCs -------------------------------------------------------------------
module "vpc_security" {
  source          = "../vpc"
  name_prefix     = "${var.name_prefix}-security"
  vpc_cidr        = local.sec
  azs             = var.azs
  subnets         = local.security_subnets
  create_igw      = true
  create_nat      = true
  security_groups = local.fw_security_groups
  tags            = merge(var.tags, { Role = "security" })
}

module "vpc_mgmt" {
  source      = "../vpc"
  name_prefix = "${var.name_prefix}-mgmt"
  vpc_cidr    = local.mg
  azs         = var.azs
  subnets     = local.mgmt_subnets
  create_igw  = true
  create_nat  = true
  tags        = merge(var.tags, { Role = "management" })
}

module "vpc_spoke1" {
  source      = "../vpc"
  name_prefix = "${var.name_prefix}-spoke1"
  vpc_cidr    = local.s1
  azs         = var.azs
  subnets     = local.spoke1_subnets
  tags        = merge(var.tags, { Role = "spoke1-app" })
}

module "vpc_spoke2" {
  source      = "../vpc"
  name_prefix = "${var.name_prefix}-spoke2"
  vpc_cidr    = local.s2
  azs         = var.azs
  subnets     = local.spoke2_subnets
  tags        = merge(var.tags, { Role = "spoke2-dc" })
}

# --- Transit Gateway --------------------------------------------------------
module "transit_gateway" {
  source      = "../transit_gateway"
  name_prefix = var.name_prefix

  attachments = {
    security = { vpc_id = module.vpc_security.vpc_id, vpc_cidr = local.sec, subnet_ids = module.vpc_security.subnet_ids_by_role["tgw"], associate_with = "security" }
    mgmt     = { vpc_id = module.vpc_mgmt.vpc_id, vpc_cidr = local.mg, subnet_ids = module.vpc_mgmt.subnet_ids_by_role["tgw"], associate_with = "spoke" }
    spoke1   = { vpc_id = module.vpc_spoke1.vpc_id, vpc_cidr = local.s1, subnet_ids = module.vpc_spoke1.subnet_ids_by_role["tgw"], associate_with = "spoke" }
    spoke2   = { vpc_id = module.vpc_spoke2.vpc_id, vpc_cidr = local.s2, subnet_ids = module.vpc_spoke2.subnet_ids_by_role["tgw"], associate_with = "spoke" }
  }

  # Keyed by static "<role>-<az>" ids so the TGW module's for_each keys are known
  # at plan time (route table ids are values, not keys).
  # sec-spoke2-*: the FW's mgmt interface (like Panorama's own mgmt-plane
  # lookups) needs this to reach the spoke2 DC for GP's LDAP bind — LDAP auth
  # profiles bind from the mgmt interface by default. Without it, traffic to
  # the DC's CIDR falls through to the mgmt subnet's default NAT route instead
  # of TGW. Mirrors the Panorama<->FW-mgmt pattern above.
  tgw_routes_in_vpc = merge(
    { for k, rt in module.vpc_mgmt.route_table_ids : "mgmt-${k}" => { route_table_id = rt, destination_cidr_block = local.sec }
    if startswith(k, "panorama-") || startswith(k, "ssm-") },
    { for k, rt in module.vpc_security.route_table_ids : "sec-${k}" => { route_table_id = rt, destination_cidr_block = local.mg }
    if startswith(k, "mgmt-") },
    { for k, rt in module.vpc_security.route_table_ids : "sec-spoke2-${k}" => { route_table_id = rt, destination_cidr_block = local.s2 }
    if startswith(k, "mgmt-") },
  )

  tags = var.tags
}

# --- Bootstrap (FW IAM + init-cfg) ------------------------------------------
module "bootstrap" {
  source      = "../bootstrap"
  name_prefix = var.name_prefix

  panorama_server                       = var.panorama_private_ip
  panorama_template_stack               = var.panorama_template_stack
  panorama_device_group                 = var.panorama_device_group
  panorama_vm_auth_key                  = var.panorama_vm_auth_key
  fw_auth_code                          = var.fw_auth_code
  vm_series_auto_registration_pin_id    = var.fw_registration_pin_id
  vm_series_auto_registration_pin_value = var.fw_registration_pin_value

  dns_primary   = cidrhost(local.sec, 2)
  dns_secondary = var.dns_secondary

  tags = var.tags
}

# --- Panorama (+ SSM jump host) — primary region only -----------------------
module "panorama" {
  count       = var.create_panorama ? 1 : 0
  source      = "../panorama"
  name_prefix = var.name_prefix

  vpc_id             = module.vpc_mgmt.vpc_id
  panorama_subnet_id = module.vpc_mgmt.subnet_ids_by_role["panorama"][0]
  ssm_subnet_id      = module.vpc_mgmt.subnet_ids_by_role["ssm"][0]

  panorama_private_ip = var.panorama_private_ip
  # local.mg/local.sec cover this region's mgmt + firewalls. var.remote_fw_cidrs
  # adds the SECONDARY region's firewall (security-VPC) CIDRs so that region's
  # firewalls — reaching this Panorama over cross-region TGW peering — can open
  # the PAN-OS control-plane connection (3978/28443) INBOUND to it. WITHOUT this,
  # secondary-region firewalls stay Connected=no (Panorama's own SG only allows
  # the local region's CIDRs, so 10.20/16 FW mgmt is dropped).
  allowed_mgmt_cidrs = concat([local.mg, local.sec], var.remote_fw_cidrs)

  panorama_instance_type = var.panorama_instance_type
  panorama_ami_id        = var.panorama_ami_id
  panorama_version       = var.panorama_version
  log_disk_size_gb       = var.panorama_log_disk_size_gb
  key_name               = local.key_name

  admin_username       = var.panorama_admin_username
  admin_password       = var.panorama_admin_password
  ssh_private_key_file = var.ssh_private_key_file

  tags = var.tags
}

# --- Firewalls (Active/Passive HA) ------------------------------------------
module "firewall" {
  source      = "../firewall"
  name_prefix = var.name_prefix

  mgmt_subnet_id    = module.vpc_security.subnet_ids_by_role["mgmt"][0]
  untrust_subnet_id = module.vpc_security.subnet_ids_by_role["untrust"][0]
  trust_subnet_id   = module.vpc_security.subnet_ids_by_role["trust"][0]
  ha2_subnet_id     = module.vpc_security.subnet_ids_by_role["ha2"][0]

  mgmt_subnet_cidr    = local.security_subnets["mgmt"].cidrs[0]
  untrust_subnet_cidr = local.security_subnets["untrust"].cidrs[0]
  trust_subnet_cidr   = local.security_subnets["trust"].cidrs[0]
  ha2_subnet_cidr     = local.security_subnets["ha2"].cidrs[0]

  mgmt_sg_id    = module.vpc_security.security_group_ids["fw-mgmt"]
  untrust_sg_id = module.vpc_security.security_group_ids["fw-untrust"]
  trust_sg_id   = module.vpc_security.security_group_ids["fw-trust"]
  ha2_sg_id     = module.vpc_security.security_group_ids["fw-ha2"]

  instance_type         = var.fw_instance_type
  vmseries_version      = var.vmseries_version
  instance_profile_name = module.bootstrap.instance_profile_name
  user_data_base64      = module.bootstrap.user_data
  key_name              = local.key_name

  tags = var.tags
}

# --- Dataplane routing ------------------------------------------------------
module "routing" {
  source = "../routing"

  transit_gateway_id         = module.transit_gateway.transit_gateway_id
  tgw_spoke_route_table_id   = module.transit_gateway.spoke_route_table_id
  tgw_security_attachment_id = module.transit_gateway.attachment_ids["security"]
  active_trust_eni_id        = module.firewall.active_trust_eni_id

  # Maps keyed by static "<role>-<az>" so the routing module's for_each keys are
  # known at plan time (route table ids are values, not keys).
  security_tgw_attach_route_table_ids = { for k, rt in module.vpc_security.route_table_ids : k => rt if startswith(k, "tgw-") }
  security_trust_route_table_ids      = { for k, rt in module.vpc_security.route_table_ids : k => rt if startswith(k, "trust-") }
  spoke_workload_route_table_ids = merge(
    { for k, rt in module.vpc_spoke1.route_table_ids : "spoke1-${k}" => rt if startswith(k, "workload-") },
    { for k, rt in module.vpc_spoke2.route_table_ids : "spoke2-${k}" => rt if startswith(k, "workload-") },
  )

  tags = var.tags
}

# --- App path (optional) ----------------------------------------------------
module "loadbalancer" {
  count       = var.create_app ? 1 : 0
  source      = "../loadbalancer"
  name_prefix = var.name_prefix

  vpc_id     = module.vpc_security.vpc_id
  subnet_ids = module.vpc_security.subnet_ids_by_role["untrust"]
  target_ips = values(module.firewall.untrust_primary_ips)

  tags = var.tags
}

module "cloudfront" {
  count              = var.create_app ? 1 : 0
  source             = "../cloudfront"
  name_prefix        = var.name_prefix
  origin_domain_name = module.loadbalancer[0].nlb_dns_name
  tags               = var.tags
}

module "spoke1_app" {
  count       = var.create_app ? 1 : 0
  source      = "../spoke1_app"
  name_prefix = var.name_prefix

  vpc_id     = module.vpc_spoke1.vpc_id
  subnet_id  = module.vpc_spoke1.subnet_ids_by_role["workload"][0]
  private_ip = cidrhost(local.spoke1_subnets["workload"].cidrs[0], 10)
  key_name   = local.key_name

  tags       = var.tags
  depends_on = [module.routing]
}

# --- Spoke2 Windows DC (optional) -------------------------------------------
module "spoke2_dc" {
  count       = var.create_dc ? 1 : 0
  source      = "../spoke2_dc"
  name_prefix = var.name_prefix

  vpc_id     = module.vpc_spoke2.vpc_id
  subnet_id  = module.vpc_spoke2.subnet_ids_by_role["workload"][0]
  private_ip = cidrhost(local.spoke2_subnets["workload"].cidrs[0], 10)

  # AWS reserves the base-of-CIDR+2 address for the Amazon-provided DNS
  # resolver in every VPC — used as the AD DNS server's forwarder post-promotion.
  dns_resolver_ip = cidrhost(local.s2, 2)

  domain_name        = var.dc_domain_name
  safe_mode_password = var.dc_safe_mode_password
  promote_to_dc      = var.dc_promote_to_dc
  key_name           = local.key_name

  # Additional-DC mode (Region B): join the existing forest + replicate from the
  # primary DC instead of creating a new forest.
  is_additional_dc      = var.dc_is_additional
  primary_dc_ip         = var.dc_primary_ip
  domain_admin_user     = var.dc_domain_admin_user
  domain_admin_password = var.dc_domain_admin_password

  ad_test_user_name     = var.dc_ad_test_user_name
  ad_test_user_password = var.dc_ad_test_user_password

  tags       = var.tags
  depends_on = [module.routing]
}

# HTTP->HTTPS redirect ALB for the GP portal (behind the GA :80 listener). Only
# created when enabled — see modules/http_redirect_alb for the rationale. Placed
# in the security VPC's public untrust subnets (internet-facing, 2 AZs).
module "http_redirect_alb" {
  count       = var.enable_http_redirect ? 1 : 0
  source      = "../http_redirect_alb"
  name_prefix = var.name_prefix

  vpc_id     = module.vpc_security.vpc_id
  subnet_ids = module.vpc_security.subnet_ids_by_role["untrust"]

  tags = var.tags
}
