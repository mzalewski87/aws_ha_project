variable "region" {
  type    = string
  default = "eu-central-1"
}
variable "name_prefix" {
  type    = string
  default = "awsha-a"
}

# From the root stack (terraform output):
variable "transit_gateway_id" {
  description = "Region A TGW ID (root output transit_gateway_ids.region_a)."
  type        = string
}
variable "mgmt_vpc_id" {
  description = "Region A MGMT VPC ID (for the EDL server)."
  type        = string
}
variable "edl_subnet_id" {
  description = "MGMT VPC subnet ID for the EDL server (e.g. the ssm subnet)."
  type        = string
}
variable "security_vpc_cidr" {
  description = "Region A security VPC CIDR (FW mgmt source for the EDL nginx allowlist)."
  type        = string
  default     = "10.10.0.0/16"
}

variable "eks_vpc_cidr" {
  type    = string
  default = "10.14.0.0/16"
}
variable "edl_private_ip" {
  type    = string
  default = "10.11.10.20"
}

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}
variable "wordpress_password" {
  type      = string
  sensitive = true
  default   = ""
}
variable "wordpress_lb_hostname" {
  description = "WordPress LoadBalancer hostname (post-apply) — set to create the CloudFront distribution."
  type        = string
  default     = ""
}

variable "key_name" {
  type    = string
  default = null
}
variable "tags" {
  type    = map(string)
  default = { Project = "aws-vmseries-ha-globalprotect", Component = "eks" }
}
