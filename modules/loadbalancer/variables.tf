###############################################################################
# modules/loadbalancer — variables
#
# Public NLB "sandwich" for the APP inbound path (Apache/WordPress) — NOT for
# GlobalProtect (ADR D1: GP terminates client VPN directly on the FW EIP).
# IP-type target group points at the FW untrust ENIs; the FW then DNATs to the
# backend app. In an Active/Passive pair the passive FW fails the health check,
# so the NLB naturally sends only to the active FW.
###############################################################################

variable "name_prefix" {
  description = "Name prefix, e.g. \"awsha-a\"."
  type        = string
}

variable "vpc_id" {
  description = "Security VPC ID (where the FW untrust ENIs live)."
  type        = string
}

variable "subnet_ids" {
  description = "Public (untrust) subnet IDs for the NLB nodes (one per AZ)."
  type        = list(string)
}

variable "target_ips" {
  description = "FW untrust primary IPs to register as IP targets (both FWs)."
  type        = list(string)
}

variable "listeners" {
  description = "TCP listener ports forwarded to the FW untrust targets."
  type        = list(number)
  default     = [80, 443]
}

variable "health_check_port" {
  description = "TCP port used for target health checks."
  type        = number
  default     = 443
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}

variable "cloudfront_only" {
  description = "Give the NLB a security group that admits only CloudFront's origin-facing ranges. Enabling it on an existing NLB replaces the NLB."
  type        = bool
  default     = false
}

variable "cloudfront_origin_ports" {
  description = "With cloudfront_only: the NLB port CloudFront connects to (the distribution's origin port). Only this listener is created then. One port only: the CloudFront prefix list weighs ~55 rules per port against the 60-rule security-group quota."
  type        = list(number)
  default     = [80]
  validation {
    condition     = length(var.cloudfront_origin_ports) == 1
    error_message = "cloudfront_origin_ports must hold exactly one port."
  }
}
