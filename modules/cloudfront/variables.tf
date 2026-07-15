###############################################################################
# modules/cloudfront — variables
#
# CloudFront in front of the app NLB (Front Door replacement, ADR D10). Client
# -> CloudFront (TLS terminate) -> app NLB -> VM-Series (inspect + DNAT) -> app.
###############################################################################

variable "name_prefix" {
  description = "Name prefix, e.g. \"awsha-a\"."
  type        = string
}

variable "origin_domain_name" {
  description = "Origin hostname — the app NLB DNS name."
  type        = string
}

variable "origin_http_port" {
  description = "Origin HTTP port (Apache has no TLS; CloudFront speaks HTTP to origin)."
  type        = number
  default     = 80
}

variable "origin_protocol_policy" {
  description = "How CloudFront connects to the origin (http-only, https-only, match-viewer)."
  type        = string
  default     = "http-only"
}

variable "price_class" {
  description = "CloudFront price class."
  type        = string
  default     = "PriceClass_100"
}

variable "comment" {
  description = "Distribution comment."
  type        = string
  default     = "app ingress via VM-Series"
}

variable "tags" {
  description = "Extra tags merged onto the distribution."
  type        = map(string)
  default     = {}
}
