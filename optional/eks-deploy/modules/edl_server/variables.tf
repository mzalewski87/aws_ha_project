variable "name_prefix" { type = string }
variable "vpc_id" {
  description = "MGMT VPC ID (EDL server placement)."
  type        = string
}
variable "subnet_id" {
  description = "MGMT VPC subnet ID for the EDL server."
  type        = string
}
variable "private_ip" { type = string }
variable "region" {
  description = "AWS region (for the EDL FQDN/IP generation)."
  type        = string
}
variable "mgmt_cidr" {
  description = "CIDR substituted into the nginx allow list (FW mgmt / security VPC)."
  type        = string
}
variable "allowed_cidrs" {
  description = "CIDRs allowed to pull the EDL over HTTP."
  type        = list(string)
}
variable "instance_type" {
  type    = string
  default = "t3.micro"
}
variable "key_name" {
  type    = string
  default = null
}
variable "tags" {
  type    = map(string)
  default = {}
}
