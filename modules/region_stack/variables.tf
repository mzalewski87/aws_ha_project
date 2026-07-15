###############################################################################
# modules/region_stack — variables
#
# Composes one complete regional stack (VPCs + TGW + bootstrap + FWs + routing
# + optional Panorama / app / DC) from the region-parameterized building-block
# modules. Root instantiates it once per region (A on the default provider, B on
# aws.region_b). Subnet CIDRs are derived from the /16 VPC CIDRs via cidrsubnet,
# so a region is fully described by its four VPC CIDRs + AZ list.
###############################################################################

variable "name_prefix" {
  description = "Per-region prefix, e.g. \"awsha-a\" or \"awsha-b\"."
  type        = string
}

variable "region" {
  description = "AWS region name (tagging only; the provider sets the actual region)."
  type        = string
}

variable "azs" {
  description = "Two AZ names in this region."
  type        = list(string)
}

# --- CIDR plan (per region /16 per VPC) -------------------------------------
variable "security_vpc_cidr" { type = string }
variable "mgmt_vpc_cidr" { type = string }
variable "spoke1_vpc_cidr" { type = string }
variable "spoke2_vpc_cidr" { type = string }

# --- Panorama (single Panorama manages all regions — ADR D6) ----------------
variable "create_panorama" {
  description = "Deploy Panorama + SSM jump host in this region (true for the primary region only)."
  type        = bool
  default     = true
}
variable "panorama_private_ip" {
  description = "Panorama private IP (this region if create_panorama, else the shared/primary Panorama IP used by bootstrap)."
  type        = string
}
variable "panorama_instance_type" {
  type    = string
  default = "m5.4xlarge"
}
variable "panorama_ami_id" {
  type    = string
  default = null
}
variable "panorama_log_disk_size_gb" {
  type    = number
  default = 2000
}

# --- Bootstrap / init-cfg ----------------------------------------------------
variable "panorama_template_stack" { type = string }
variable "panorama_device_group" { type = string }
variable "panorama_vm_auth_key" {
  type      = string
  default   = ""
  sensitive = true
}
variable "fw_auth_code" {
  type      = string
  default   = ""
  sensitive = true
}
variable "fw_registration_pin_id" {
  type      = string
  default   = ""
  sensitive = true
}
variable "fw_registration_pin_value" {
  type      = string
  default   = ""
  sensitive = true
}
variable "dns_secondary" {
  type    = string
  default = "1.1.1.1"
}

# --- Firewalls / instances ---------------------------------------------------
variable "fw_instance_type" {
  type    = string
  default = "m5.xlarge"
}
variable "key_name" {
  type    = string
  default = null
}

variable "ssh_public_key" {
  description = "OpenSSH public key. When set (and key_name != null), this region creates its own EC2 key pair named key_name (EC2 key pairs are region-local). Empty = assume key_name already exists in this region."
  type        = string
  default     = ""
}

variable "panorama_admin_username" {
  type    = string
  default = "admin"
}

variable "panorama_admin_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "ssh_private_key_file" {
  type    = string
  default = null
}

variable "vmseries_version" {
  type    = string
  default = "11.1.15"
}

variable "panorama_version" {
  type    = string
  default = "11.1.15"
}

# --- Optional components -----------------------------------------------------
variable "create_app" {
  description = "Deploy the app path (NLB + CloudFront + spoke1 Apache)."
  type        = bool
  default     = true
}
variable "create_dc" {
  description = "Deploy the spoke2 Windows DC."
  type        = bool
  default     = true
}
variable "dc_domain_name" {
  type    = string
  default = "panw.labs"
}
variable "dc_safe_mode_password" {
  type      = string
  default   = ""
  sensitive = true
}
variable "dc_promote_to_dc" {
  type    = bool
  default = true
}

variable "dc_is_additional" {
  description = "true = promote this region's DC as an ADDITIONAL DC in the existing forest (replica), instead of creating a new forest. Region B uses this."
  type        = bool
  default     = false
}

variable "dc_primary_ip" {
  description = "Primary DC private IP to join + replicate from (required when dc_is_additional)."
  type        = string
  default     = ""
}

variable "dc_domain_admin_user" {
  description = "Domain admin UPN to promote the additional DC (required when dc_is_additional), e.g. admin@panw.labs."
  type        = string
  default     = ""
}

variable "dc_domain_admin_password" {
  description = "Password for dc_domain_admin_user."
  type        = string
  default     = ""
  sensitive   = true
}

variable "dc_ad_test_user_name" {
  type    = string
  default = "admin"
}

variable "dc_vpn_group" {
  description = "AD group gating GlobalProtect access (created on the DC; the test user is added to it)."
  type        = string
  default     = "vpnusers"
}

variable "dc_ad_test_user_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "tags" {
  description = "Extra tags merged onto everything in this region."
  type        = map(string)
  default     = {}
}

variable "remote_panorama_cidr" {
  description = "mgmt VPC CIDR of the region that HOSTS Panorama, for the fw-mgmt SG on a SECONDARY region (so the shared Panorama over cross-region peering can connect back to the FWs). Empty on the primary region (Panorama is local)."
  type        = string
  default     = ""
}

variable "remote_fw_cidrs" {
  description = "Security-VPC CIDRs of OTHER regions' firewalls, for the Panorama SG on the PRIMARY region (so remote firewalls reaching this Panorama over cross-region TGW peering can open the PAN-OS control plane 3978/28443 inbound). Empty on secondary regions (they host no Panorama)."
  type        = list(string)
  default     = []
}

variable "enable_http_redirect" {
  description = "Create an HTTP->HTTPS 301 redirect ALB in this region (registered behind the Global Accelerator :80 listener). See modules/http_redirect_alb."
  type        = bool
  default     = false
}
