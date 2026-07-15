###############################################################################
# modules/panorama — variables
#
# Self-hosted Panorama on EC2 (BYOL) + a small SSM jump host for management-plane
# access. PAN-OS/Panorama does NOT run the AWS SSM agent, so ADR D8's "SSM
# port-forward" is realised via AWS-StartPortForwardingSessionToRemoteHost through
# an SSM-managed Amazon Linux jump host -> Panorama:443. No public IP, no bastion.
###############################################################################

variable "name_prefix" {
  description = "Name prefix, e.g. \"awsha-a\"."
  type        = string
}

variable "vpc_id" {
  description = "Management VPC ID (for the Panorama + jump host security groups)."
  type        = string
}

variable "panorama_subnet_id" {
  description = "Subnet ID for the Panorama ENI (management VPC, AZ a)."
  type        = string
}

variable "ssm_subnet_id" {
  description = "Subnet ID for the SSM jump host (management VPC)."
  type        = string
}

variable "panorama_private_ip" {
  description = "Static private IP for Panorama within panorama_subnet_id."
  type        = string
}

variable "allowed_mgmt_cidrs" {
  description = "CIDRs allowed to reach Panorama mgmt (22/443) and PAN-OS control plane (3978/28443). Typically the mgmt VPC CIDR + the security VPC CIDR (FW mgmt)."
  type        = list(string)
}

# --- Panorama instance -------------------------------------------------------

variable "panorama_instance_type" {
  description = "EC2 instance type for Panorama (PANW sizing; min 16 vCPU / 32 GB for current PAN-OS)."
  type        = string
  default     = "m5.4xlarge"
}

variable "panorama_ami_id" {
  description = "Explicit Panorama AMI ID. If null, looked up via panorama_product_code + panorama_version (aws-marketplace, requires a one-time Marketplace subscription)."
  type        = string
  default     = null
}

variable "panorama_product_code" {
  description = "AWS Marketplace product code for the Panorama BYOL AMI (used when panorama_ami_id is null)."
  type        = string
  default     = "eclz7j04vu9lf8ont8ta3n17o"
}

variable "panorama_version" {
  description = "Panorama PAN-OS version to pin, e.g. \"11.1.15\". A trailing \"*\" is added to match hotfix builds. MUST be >= the VM-Series (vmseries_version): Panorama can manage same-or-older firewalls, never newer."
  type        = string
  default     = "11.1.15"
}

variable "log_disk_size_gb" {
  description = "Size of the Panorama log-collection EBS volume (analog of the Azure 2 TB data disk)."
  type        = number
  default     = 2000
}

variable "log_disk_type" {
  description = "EBS volume type for the log disk."
  type        = string
  default     = "gp3"
}

variable "root_disk_size_gb" {
  description = "Root EBS size for Panorama."
  type        = number
  default     = 81
}

# --- SSM jump host -----------------------------------------------------------

variable "jumphost_instance_type" {
  description = "Instance type for the SSM jump host."
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Optional EC2 key pair name for Panorama (initial admin SSH key) and the jump host. null = no key pair (jump host reachable via SSM only)."
  type        = string
  default     = null
}

variable "admin_username" {
  description = "Panorama admin username set at first boot (also used by the panos provider in Phase 2a)."
  type        = string
  default     = "admin"
}

variable "admin_password" {
  description = "Panorama admin password. PAN-OS on AWS has no platform password injection, so Terraform sets it over SSH (key auth) at first boot. Empty = skip (no auto-set)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ssh_private_key_file" {
  description = "Local path to the private key matching key_name, used only by the first-boot password provisioner. null = derive ~/.ssh/<key_name>.pem."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
