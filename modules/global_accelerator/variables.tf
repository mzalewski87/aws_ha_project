###############################################################################
# modules/global_accelerator — variables
#
# Fronts the GP PORTAL only (ADR D3): 2 static anycast IPs, TCP 443 (+ UDP 4501
# for IPSec), health-checked per-region portal EIP endpoints, sub-minute
# cross-region failover. GP GATEWAYS use GP-native failover — no LB (D4).
###############################################################################

variable "name_prefix" {
  description = "Name prefix, e.g. \"awsha\"."
  type        = string
}

variable "endpoint_groups" {
  description = "Per-region endpoints: the FW public EIP allocation ID in each region, plus (optionally) that region's HTTP->HTTPS redirect ALB ARN for the :80 listener."
  type = list(object({
    region            = string
    eip_allocation_id = string
    redirect_alb_arn  = optional(string)
  }))
}

variable "listeners" {
  description = "GA listeners. Default: TCP 80 (HTTP->HTTPS portal redirect) + TCP 443 (portal/SSL) + UDP 4501 (IPSec). The :80 listener is flagged http_redirect: when an endpoint group supplies redirect_alb_arn, :80 points at that ALB (which issues the 301); otherwise :80 falls back to the FW EIP. GA is L4 and cannot redirect on its own, so the ALB is what actually returns the 301."
  type = list(object({
    protocol      = string
    port          = number
    http_redirect = optional(bool, false)
  }))
  default = [
    { protocol = "TCP", port = 80, http_redirect = true },
    { protocol = "TCP", port = 443 },
    { protocol = "UDP", port = 4501 },
  ]
}

variable "health_check_port" {
  description = "TCP port GA health-checks on each portal EIP (gates the region)."
  type        = number
  default     = 443
}

variable "tags" {
  description = "Extra tags merged onto the accelerator."
  type        = map(string)
  default     = {}
}
