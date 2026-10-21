variable "name_prefix" {
  type = string
}
variable "vpc_id" {
  description = "VPC hosting the ALB (public subnets) and the Guacamole host (private subnet)."
  type        = string
}
variable "alb_subnet_ids" {
  description = "Public subnets (>= 2 AZs) for the internet-facing ALB."
  type        = list(string)
}
variable "host_subnet_id" {
  description = "Private subnet (NAT egress for Docker image pulls) for the Guacamole host."
  type        = string
}
variable "certificate_arn" {
  description = "Issued ACM certificate (same region as the ALB) for the public hostname."
  type        = string
}
variable "instance_type" {
  type    = string
  default = "t3.small"
}
variable "key_name" {
  type = string
}
variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB on 443/80. Default is the open internet (the TOTP-protected login is the control); narrow it to harden."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
variable "guacamole_admin_user" {
  description = "Guacamole admin login. The default guacadmin account is replaced, not kept."
  type        = string
  default     = "gadmin"
}
variable "rdp_target_host" {
  description = "Private IP of the RDP target (the domain controller)."
  type        = string
}
variable "rdp_target_name" {
  description = "Connection display name in Guacamole."
  type        = string
  default     = "Domain Controller"
}
variable "rdp_target_domain" {
  description = "AD domain passed to the RDP connection (NetBIOS/FQDN)."
  type        = string
  default     = ""
}
variable "rdp_username" {
  description = "RDP login for the pre-provisioned connection. Empty = users type credentials at connect time (more secure)."
  type        = string
  default     = ""
}
variable "rdp_password" {
  description = "RDP password for the pre-provisioned connection (stored in Secrets Manager, never in user-data). Empty = prompt at connect."
  type        = string
  default     = ""
  sensitive   = true
}
variable "tags" {
  type    = map(string)
  default = {}
}
