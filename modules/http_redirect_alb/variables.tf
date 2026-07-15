variable "name_prefix" {
  description = "Resource-name prefix (region_stack passes the per-region prefix)."
  type        = string
}

variable "vpc_id" {
  description = "VPC to place the ALB + its security group in (the security VPC)."
  type        = string
}

variable "subnet_ids" {
  description = "Public subnet IDs for the internet-facing ALB — at least two in different AZs (the security VPC untrust subnets)."
  type        = list(string)
}

variable "https_port" {
  description = "Port the 301 redirects to."
  type        = number
  default     = 443
}

variable "tags" {
  description = "Tags to apply."
  type        = map(string)
  default     = {}
}
