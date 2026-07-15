###############################################################################
# modules/firewall — variables
#
# VM-Series Active/Passive HA pair (ADR D1). Same-AZ placement: an ENI/secondary
# IP cannot cross an AZ, so both FWs sit in one AZ and the PAN-OS AWS HA plugin
# moves the floating secondary IP + EIP (AssociateAddress) and rewrites the
# dataplane route (ReplaceRoute) on failover. Whole-AZ loss is covered by the
# OTHER region (GP-native gateway failover), per the multi-region design.
###############################################################################

variable "name_prefix" {
  description = "Name prefix, e.g. \"awsha-a\"."
  type        = string
}

# --- Subnets (all in the SAME AZ for the A/P pair) ---------------------------

variable "mgmt_subnet_id" {
  description = "FW mgmt subnet ID (eth0)."
  type        = string
}
variable "untrust_subnet_id" {
  description = "FW untrust subnet ID (eth1 / ethernet1/1, public)."
  type        = string
}
variable "trust_subnet_id" {
  description = "FW trust subnet ID (eth2 / ethernet1/2)."
  type        = string
}
variable "ha2_subnet_id" {
  description = "FW HA2 state-sync subnet ID (eth3)."
  type        = string
}

variable "mgmt_subnet_cidr" {
  description = "FW mgmt subnet CIDR (used to compute static IPs)."
  type        = string
}
variable "untrust_subnet_cidr" {
  description = "FW untrust subnet CIDR."
  type        = string
}
variable "trust_subnet_cidr" {
  description = "FW trust subnet CIDR."
  type        = string
}
variable "ha2_subnet_cidr" {
  description = "FW HA2 subnet CIDR."
  type        = string
}

# --- Security groups ---------------------------------------------------------

variable "mgmt_sg_id" {
  description = "Security group ID for the FW mgmt ENI."
  type        = string
}
variable "untrust_sg_id" {
  description = "Security group ID for the FW untrust ENI."
  type        = string
}
variable "trust_sg_id" {
  description = "Security group ID for the FW trust ENI."
  type        = string
}
variable "ha2_sg_id" {
  description = "Security group ID for the FW HA2 ENI."
  type        = string
}

# --- Image / instance --------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type for VM-Series (min 4 vCPU / 4 ENIs; PANW sizing). Default m5.xlarge = 4 vCPU; m5.2xlarge = 8 vCPU for throughput headroom."
  type        = string
  default     = "m5.xlarge"
}

variable "vmseries_ami_id" {
  description = "Explicit VM-Series AMI ID. null = look up via product code + version (Marketplace, one-time subscription required)."
  type        = string
  default     = null
}

variable "vmseries_product_code" {
  description = "AWS Marketplace product code for the VM-Series AMI (default = BYOL)."
  type        = string
  default     = "6njl1pau431dv1qxipg63mvah"
}

variable "vmseries_version" {
  description = "VM-Series PAN-OS version to pin, e.g. \"11.1.15\". A trailing \"*\" is added to match hotfix builds (11.1.6 -> 11.1.6-h33). Panorama MUST run this version or newer."
  type        = string
  default     = "11.1.15"
}

variable "instance_profile_name" {
  description = "IAM instance profile (HA-plugin + SSM) from the bootstrap module."
  type        = string
}

variable "user_data_base64" {
  description = "Map of FW hostname => base64 init-cfg (EC2 user-data) from the bootstrap module."
  type        = map(string)
  sensitive   = true
}

variable "key_name" {
  description = "Optional EC2 key pair name (initial admin SSH key)."
  type        = string
  default     = null
}

# --- IP layout ---------------------------------------------------------------

variable "fw_host_offsets" {
  description = "Host offsets within each subnet for the primary IPs of fw1/fw2."
  type        = map(number)
  default     = { fw1 = 11, fw2 = 12 }
}

variable "floating_host_offset" {
  description = "Host offset (in the untrust subnet) of the floating IP that carries the public EIP and moves on failover."
  type        = number
  default     = 100
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
