variable "name" {
  type = string
}
variable "description" {
  type    = string
  default = "Managed by Terraform"
}
variable "scope" {
  description = "REGIONAL (ALB, same region) or CLOUDFRONT (provider must be us-east-1)."
  type        = string
  validation {
    condition     = contains(["REGIONAL", "CLOUDFRONT"], var.scope)
    error_message = "scope must be REGIONAL or CLOUDFRONT."
  }
}
variable "allowed_countries" {
  description = "ISO 3166-1 alpha-2 codes allowed to reach the endpoint, e.g. [\"PL\"]. Empty = no geo rule."
  type        = list(string)
  default     = []
}
variable "rate_limit" {
  description = "Max requests per source IP in any 5-minute window (WAF accepts 10 - 2000000000)."
  type        = number
  default     = 1000
  validation {
    condition     = var.rate_limit >= 10 && var.rate_limit <= 2000000000
    error_message = "rate_limit must be between 10 and 2000000000."
  }
}
variable "resource_arns" {
  description = "REGIONAL only: ALB ARNs to attach the ACL to."
  type        = list(string)
  default     = []
}
variable "tags" {
  type    = map(string)
  default = {}
}
