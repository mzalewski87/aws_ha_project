###############################################################################
# modules/spoke2_dc — variables
#
# Windows Server 2022 in spoke2, optionally promoted to an AD DS forest via
# user-data PowerShell (ports the Azure spoke2_dc DC concept). Private only;
# managed via SSM/RDP over the internal path through the FWs.
###############################################################################

variable "name_prefix" {
  description = "Name prefix, e.g. \"awsha-a\"."
  type        = string
}

variable "vpc_id" {
  description = "Spoke2 VPC ID (for the DC security group)."
  type        = string
}

variable "subnet_id" {
  description = "Spoke2 workload subnet ID."
  type        = string
}

variable "private_ip" {
  description = "Static private IP for the DC (becomes the domain DNS server)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the DC."
  type        = string
  default     = "t3.large"
}

variable "domain_name" {
  description = "AD DS domain FQDN (e.g. panw.labs)."
  type        = string
  default     = "panw.labs"
}

variable "safe_mode_password" {
  description = "Directory Services Restore Mode (DSRM) password used when promoting the forest."
  type        = string
  default     = ""
  sensitive   = true
}

variable "dns_resolver_ip" {
  description = "Resolver added as a DNS forwarder after promotion (the VPC's own Amazon-provided DNS, base of the spoke2 CIDR + 2), so the DC can still resolve public names once -InstallDns makes it authoritative for its own AD zone."
  type        = string
}

variable "promote_to_dc" {
  description = "Run AD DS promotion in user-data. false = plain Windows Server. When true, is_additional_dc chooses forest-create vs additional-DC."
  type        = bool
  default     = true
}

variable "is_additional_dc" {
  description = "false = create a new forest (Install-ADDSForest, the primary/Region-A DC). true = join the EXISTING domain and promote as an ADDITIONAL domain controller (Install-ADDSDomainController) that replicates from primary_dc_ip — used for the Region-B DC. Requires primary_dc_ip + domain_admin_user/password and cross-region reachability to the primary DC."
  type        = bool
  default     = false
}

variable "primary_dc_ip" {
  description = "Private IP of the existing (primary) DC to join + replicate from. Required when is_additional_dc = true; the new box points its DNS client here to find the domain before promotion."
  type        = string
  default     = ""
}

variable "domain_admin_user" {
  description = "Domain admin UPN used to promote the additional DC, e.g. \"admin@panw.labs\". Required when is_additional_dc = true (the account must be in Domain Admins)."
  type        = string
  default     = ""
}

variable "domain_admin_password" {
  description = "Password for domain_admin_user. Required when is_additional_dc = true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "allowed_mgmt_cidrs" {
  description = "CIDRs allowed to RDP (3389) to the DC."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "allowed_internal_cidrs" {
  description = "CIDRs allowed AD/DNS/Kerberos/LDAP access to the DC."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "key_name" {
  description = "EC2 key pair (used to decrypt the Windows Administrator password)."
  type        = string
  default     = null
}

variable "ad_test_user_name" {
  description = "AD user created after the forest is up, for GP LDAP auth testing (SSM RunCommand, see scripts/create-ad-test-user.sh)."
  type        = string
  default     = "admin"
}

variable "vpn_group" {
  description = "AD group whose members may connect via GlobalProtect (created on the DC; Panorama group-mapping + auth allow-list gate on it). The test user is added to it."
  type        = string
  default     = "vpnusers"
}

variable "ad_test_user_password" {
  description = "Password for ad_test_user_name. Empty = skip creation entirely."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
