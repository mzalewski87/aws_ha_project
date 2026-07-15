###############################################################################
# Root orchestration — one region_stack per region (ADR D2, D6).
#
# Region A (default provider) is always deployed and hosts the single Panorama
# that manages ALL regions. Region B (aws.region_b, feature-flagged by
# var.enable_region_b) reuses the same region_stack module with Region B CIDRs
# and create_panorama = false; its FWs register to the Region A Panorama over the
# cross-region TGW peering (see cross_region.tf). Global Accelerator fronts both
# regions' portal EIPs.
#
# Phased apply still uses -target within a region_stack (see README / ROADMAP).
###############################################################################

# Guard: Panorama must run the same or a NEWER PAN-OS than the firewalls it
# manages (never older). Compare major.feature.maintenance as an integer so a
# misconfigured pair fails fast at plan instead of firewalls silently staying
# Connected=no with "unsupported-version". Hotfix suffixes (e.g. "-h33") are
# ignored via the regex on the maintenance component.
locals {
  _pv       = split(".", var.panorama_version)
  _fv       = split(".", var.vmseries_version)
  _pano_int = tonumber(local._pv[0]) * 10000 + tonumber(local._pv[1]) * 100 + (length(local._pv) > 2 ? tonumber(regex("^[0-9]+", local._pv[2])) : 0)
  _fw_int   = tonumber(local._fv[0]) * 10000 + tonumber(local._fv[1]) * 100 + (length(local._fv) > 2 ? tonumber(regex("^[0-9]+", local._fv[2])) : 0)

  # The HTTP->HTTPS redirect ALB only helps when it sits behind the GA :80
  # listener (that's the only thing that routes :80 for the portal FQDN), so it
  # is created only when BOTH the redirect and Global Accelerator are enabled.
  http_redirect_on = var.enable_http_redirect && var.enable_global_accelerator
}

resource "terraform_data" "version_guard" {
  lifecycle {
    precondition {
      condition     = local._pano_int >= local._fw_int
      error_message = "panorama_version (${var.panorama_version}) must be >= vmseries_version (${var.vmseries_version}). Panorama can manage same-or-older firewalls only, never newer."
    }
  }
}

data "aws_availability_zones" "region_a" {
  state = "available"
}

data "aws_availability_zones" "region_b" {
  provider = aws.region_b
  state    = "available"
}

# ---- Region A (primary — hosts Panorama) -----------------------------------
module "region_a" {
  source      = "./modules/region_stack"
  name_prefix = "${var.name_prefix}-a"
  region      = var.region_a
  azs         = slice(data.aws_availability_zones.region_a.names, 0, 2)

  security_vpc_cidr = var.security_vpc_cidr
  mgmt_vpc_cidr     = var.mgmt_vpc_cidr
  spoke1_vpc_cidr   = var.spoke1_vpc_cidr
  spoke2_vpc_cidr   = var.spoke2_vpc_cidr

  create_panorama     = true
  panorama_private_ip = var.panorama_private_ip
  # Secondary regions' firewall (security-VPC) CIDRs, so Panorama's own SG here
  # admits the PAN-OS control plane (3978/28443) from remote firewalls reaching
  # it over cross-region TGW peering. Region B's security VPC when enabled.
  remote_fw_cidrs           = var.enable_region_b ? [var.security_vpc_cidr_b] : []
  panorama_instance_type    = var.panorama_instance_type
  panorama_ami_id           = var.panorama_ami_id
  panorama_log_disk_size_gb = var.panorama_log_disk_size_gb

  panorama_template_stack   = var.panorama_template_stack
  panorama_device_group     = var.panorama_device_group
  panorama_vm_auth_key      = var.panorama_vm_auth_key
  fw_auth_code              = var.fw_auth_code
  fw_registration_pin_id    = var.fw_registration_pin_id
  fw_registration_pin_value = var.fw_registration_pin_value
  dns_secondary             = var.dns_secondary

  fw_instance_type = var.fw_instance_type
  vmseries_version = var.vmseries_version
  panorama_version = var.panorama_version
  key_name         = var.key_name

  panorama_admin_username = var.panorama_admin_username
  panorama_admin_password = var.panorama_admin_password
  ssh_private_key_file    = var.ssh_private_key_file
  ssh_public_key          = var.ssh_public_key

  create_app               = true
  create_dc                = true
  dc_domain_name           = var.dc_domain_name
  dc_safe_mode_password    = var.dc_safe_mode_password
  dc_promote_to_dc         = var.dc_promote_to_dc
  dc_ad_test_user_name     = var.dc_ad_test_user_name
  dc_ad_test_user_password = var.dc_ad_test_user_password
  dc_vpn_group             = var.gp_vpn_group

  # HTTP->HTTPS redirect ALB behind the GA :80 listener (only meaningful with GA).
  enable_http_redirect = local.http_redirect_on

  tags = { Region = var.region_a }
}

# ---- Region B (secondary — Phase R2, feature-flagged) ----------------------
module "region_b" {
  count  = var.enable_region_b ? 1 : 0
  source = "./modules/region_stack"

  providers = { aws = aws.region_b }

  name_prefix = "${var.name_prefix}-b"
  region      = var.region_b
  azs         = slice(data.aws_availability_zones.region_b.names, 0, 2)

  security_vpc_cidr = var.security_vpc_cidr_b
  mgmt_vpc_cidr     = var.mgmt_vpc_cidr_b
  spoke1_vpc_cidr   = var.spoke1_vpc_cidr_b
  spoke2_vpc_cidr   = var.spoke2_vpc_cidr_b

  # Single Panorama (Region A) manages Region B too — no Panorama here.
  create_panorama     = false
  panorama_private_ip = var.panorama_private_ip # Region A Panorama, reached via peering
  # Region A mgmt VPC CIDR so Region B's fw-mgmt SG lets the shared Panorama
  # (over cross-region peering) open the PAN-OS control connection back — else
  # Region B FWs never register.
  remote_panorama_cidr = var.mgmt_vpc_cidr

  panorama_template_stack   = var.panorama_template_stack
  panorama_device_group     = var.panorama_device_group
  panorama_vm_auth_key      = var.panorama_vm_auth_key
  fw_auth_code              = var.fw_auth_code
  fw_registration_pin_id    = var.fw_registration_pin_id
  fw_registration_pin_value = var.fw_registration_pin_value
  dns_secondary             = var.dns_secondary

  fw_instance_type = var.fw_instance_type
  vmseries_version = var.vmseries_version
  key_name         = var.key_name
  ssh_public_key   = var.ssh_public_key

  create_app               = var.region_b_create_app
  create_dc                = var.region_b_create_dc
  dc_domain_name           = var.dc_domain_name
  dc_safe_mode_password    = var.dc_safe_mode_password
  dc_promote_to_dc         = var.dc_promote_to_dc
  dc_ad_test_user_name     = var.dc_ad_test_user_name
  dc_ad_test_user_password = var.dc_ad_test_user_password

  # Region B DC joins the existing panw.labs forest as a replica of the Region A
  # DC (native AD multi-master replication), so GP LDAP survives a region outage.
  # The Region A test user (made a Domain Admin) is the promotion credential.
  dc_is_additional         = true
  dc_primary_ip            = module.region_a.dc_private_ip
  dc_domain_admin_user     = "${var.dc_ad_test_user_name}@${var.dc_domain_name}"
  dc_domain_admin_password = var.dc_ad_test_user_password
  dc_vpn_group             = var.gp_vpn_group

  # HTTP->HTTPS redirect ALB behind the GA :80 listener (only meaningful with GA).
  enable_http_redirect = local.http_redirect_on

  tags = { Region = var.region_b }
}

# ---- Global Accelerator in front of the per-region portal EIPs (ADR D3) -----
module "global_accelerator" {
  count       = var.enable_global_accelerator ? 1 : 0
  source      = "./modules/global_accelerator"
  name_prefix = var.name_prefix
  providers   = { aws = aws.global }

  endpoint_groups = concat(
    [{
      region            = var.region_a
      eip_allocation_id = module.region_a.fw_public_eip_allocation_id
      redirect_alb_arn  = module.region_a.http_redirect_alb_arn
    }],
    var.enable_region_b ? [{
      region            = var.region_b
      eip_allocation_id = module.region_b[0].fw_public_eip_allocation_id
      redirect_alb_arn  = module.region_b[0].http_redirect_alb_arn
    }] : [],
  )

  tags = { Scope = "global" }
}

# ---- Optional custom domain (Route53 subdomain + Let's Encrypt) -------------
# Portal record -> Global Accelerator anycast IPs (falls back to Region A EIP if
# GA is off). Gateway records -> each region's firewall EIP. See ADR / docs.
module "custom_domain" {
  count       = var.enable_custom_domain ? 1 : 0
  source      = "./modules/custom_domain"
  name_prefix = var.name_prefix

  enable          = true
  subdomain_zone  = var.custom_domain_subdomain_zone
  portal_hostname = var.custom_domain_portal_hostname

  # Prefer the GA anycast IPs (multi-region); else the single Region A EIP.
  portal_target_ips = var.enable_global_accelerator ? flatten([
    for s in module.global_accelerator[0].accelerator_static_ips : s.ip_addresses
  ]) : [module.region_a.fw_public_eip]

  gateway_records = merge(
    { (var.custom_domain_gateway_labels["region_a"]) = module.region_a.fw_public_eip },
    var.enable_region_b ? { (var.custom_domain_gateway_labels["region_b"]) = module.region_b[0].fw_public_eip } : {},
  )

  cert_mode         = var.custom_domain_cert_mode
  letsencrypt_email = var.custom_domain_letsencrypt_email

  tags = { Scope = "custom-domain" }
}

###############################################################################
# Phase notes (see docs/ROADMAP.md):
#  - Phase 2a: cd phase2-panorama-config && terraform apply (panos workspace via
#    the SSM jump-host port-forward; module.region_a.ssm_jumphost_instance_id).
#  - Phase 2b: bash scripts/register-fw-panorama.sh (both regions' FW serials).
#  - Optional EKS/WordPress/EDL: optional/eks-deploy (see its README).
###############################################################################
