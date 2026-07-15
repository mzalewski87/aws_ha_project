variable "name_prefix" { type = string }
variable "vpc_cidr" {
  type    = string
  default = "10.14.0.0/16"
}
variable "azs" { type = list(string) }
variable "transit_gateway_id" {
  description = "Existing TGW ID from the root stack (terraform output transit_gateway_ids)."
  type        = string
}
variable "tags" {
  type    = map(string)
  default = {}
}
