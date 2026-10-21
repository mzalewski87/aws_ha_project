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
variable "management_mode" {
  description = "Central management plane: \"panorama\" (path A, self-hosted Panorama) or \"scm\" (path B, Strata Cloud Manager - no Panorama EC2)."
  type        = string
  default     = "panorama"
  validation {
    condition     = contains(["panorama", "scm"], var.management_mode)
    error_message = "management_mode must be \"panorama\" or \"scm\"."
  }
}
variable "create_panorama" {
  description = "Primary region (true for Region A only): path A deploys Panorama + its SSM jump host here; path B (scm) deploys the SSM jump host only. Guacamole and the panel also live only in this region."
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

variable "app_aliases" {
  description = "Alternate domain names for the app CloudFront distribution (e.g. [\"web.lab.example.com\"]). Needs app_acm_certificate_arn."
  type        = list(string)
  default     = []
}

variable "app_acm_certificate_arn" {
  description = "ARN of a us-east-1 ACM certificate covering app_aliases. Empty = default *.cloudfront.net certificate."
  type        = string
  default     = ""
}

variable "create_pki" {
  description = "Two-tier AD CS PKI (offline root + enterprise issuing CA) in spoke2. Mandatory component: the firewall's SSL Forward Proxy re-signing CA is issued by this PKI and domain members trust it automatically. Requires create_dc."
  type        = bool
  default     = true
}

variable "create_guacamole" {
  description = "Deploy the Guacamole RDP gateway (mgmt VPC) for browser-based access to the DC. Primary region only; needs create_dc."
  type        = bool
  default     = false
}
variable "guac_certificate_arn" {
  description = "Issued ACM certificate ARN for the Guacamole hostname (required when create_guacamole)."
  type        = string
  default     = ""
}
variable "guac_rdp_username" {
  description = "Optional RDP username pre-provisioned in the Guacamole DC connection (empty = prompt at connect)."
  type        = string
  default     = ""
}
variable "guac_rdp_password" {
  description = "Optional RDP password for the pre-provisioned connection (Secrets Manager only; empty = prompt)."
  type        = string
  default     = ""
  sensitive   = true
}
variable "guac_ldap_enabled" {
  description = "Guacamole sign-in for AD users in guac_ldap_group (LDAP to the DC; TOTP stays mandatory)."
  type        = bool
  default     = false
}
variable "guac_ldap_group" {
  description = "AD group whose members may sign in to Guacamole (CN=Users)."
  type        = string
  default     = "guacusers"
}

variable "create_panel" {
  description = "Deploy the admin/test panel (2 hosts in 2 AZs + ALB, mgmt VPC). Primary region only; needs create_dc."
  type        = bool
  default     = false
}
variable "panel_certificate_arn" {
  description = "Issued ACM certificate ARN for the panel hostname (required when create_panel)."
  type        = string
  default     = ""
}

variable "panel_enable_failover" {
  description = "Let panel operators run failover tests (adds an IAM role limited to stop/start of the firewall instances)."
  type        = bool
  default     = false
}
variable "panel_gp_fqdn" {
  description = "GlobalProtect portal FQDN the panel probes during failover tests."
  type        = string
  default     = ""
}

variable "panel_alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the panel ALB."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "panel_remote_pairs" {
  description = "Firewall pairs of OTHER regions shown (and testable) in the panel: key => {label, region, eip_allocation_id, public_ip, units = {name => {ip, id, untrust_eni, trust_eni}}}. Unit names must be unique across pairs."
  type = map(object({
    label             = string
    region            = string
    eip_allocation_id = string
    public_ip         = string
    units = map(object({
      ip          = string
      id          = string
      untrust_eni = string
      trust_eni   = string
    }))
  }))
  default = {}
}

variable "panel_ga_arn" {
  description = "Global Accelerator ARN for the panel's topology view (empty = none)."
  type        = string
  default     = ""
}

variable "app_nlb_cloudfront_only" {
  description = "Restrict the app NLB to CloudFront's origin-facing ranges (replaces an existing NLB when turned on)."
  type        = bool
  default     = false
}
variable "app_web_acl_id" {
  description = "CLOUDFRONT-scope WAF web ACL ARN for the app distribution (empty = none)."
  type        = string
  default     = ""
}
