variable "name_prefix" { type = string }
variable "origin_domain_name" {
  description = "WordPress Kubernetes LoadBalancer hostname."
  type        = string
}
variable "tags" {
  type    = map(string)
  default = {}
}
