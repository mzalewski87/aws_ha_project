###############################################################################
# modules/pki — variables
###############################################################################

variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC the CA hosts live in (spoke2, alongside the domain controller)."
  type        = string
}

variable "subnet_id" {
  description = "Subnet for both CA hosts."
  type        = string
}

variable "root_ca_private_ip" {
  description = "Static private IP for the OFFLINE root CA."
  type        = string
}

variable "sub_ca_private_ip" {
  description = "Static private IP for the enterprise issuing (subordinate) CA."
  type        = string
}

variable "instance_type" {
  description = "Instance type for the CA hosts. A CA is idle almost all the time; t3.medium is ample."
  type        = string
  default     = "t3.medium"
}

variable "domain_name" {
  description = "AD DS domain the issuing CA joins, e.g. panw.labs."
  type        = string
}

variable "dns_resolver_ip" {
  description = "Domain controller IP — the issuing CA must resolve the domain to join it."
  type        = string
}

variable "domain_admin_user" {
  description = "Domain account used to join the issuing CA and install an ENTERPRISE CA (writes to the AD configuration partition, so it must be an Enterprise Admin)."
  type        = string
}

variable "domain_admin_password" {
  description = "Password for domain_admin_user."
  type        = string
  sensitive   = true
}

variable "ca_common_name_root" {
  description = "Subject CN of the offline root CA."
  type        = string
  default     = "PANW Lab Root CA"
}

variable "ca_common_name_sub" {
  description = "Subject CN of the enterprise issuing CA."
  type        = string
  default     = "PANW Lab Issuing CA"
}

variable "root_ca_validity_years" {
  description = "Root CA self-signed lifetime. Long by design: re-keying a root means re-distributing trust everywhere."
  type        = number
  default     = 20
}

variable "sub_ca_validity_years" {
  description = "Lifetime of the issuing CA certificate signed by the root. Must be shorter than the root's remaining life."
  type        = number
  default     = 10
}

variable "allowed_internal_cidrs" {
  description = "CIDRs permitted to reach the CA hosts (AD/RPC/HTTP for AIA+CDP)."
  type        = list(string)
}

variable "key_name" {
  description = "EC2 key pair, for decrypting the Administrator password."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
