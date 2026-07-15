###############################################################################
# modules/spoke1_app — variables
#
# Apache "hello world" on EC2 in spoke1. Private only; reached inbound via
# CloudFront -> app NLB -> VM-Series (DNAT) -> this host, and egress via
# TGW -> VM-Series. See the infinite-retry installer note in main.tf.
###############################################################################

variable "name_prefix" {
  description = "Name prefix, e.g. \"awsha-a\"."
  type        = string
}

variable "vpc_id" {
  description = "Spoke1 VPC ID (for the app security group)."
  type        = string
}

variable "subnet_id" {
  description = "Spoke1 workload subnet ID."
  type        = string
}

variable "private_ip" {
  description = "Static private IP for the Apache host."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "allowed_client_cidrs" {
  description = "CIDRs allowed to reach the app on 80/443 (the FW/internal supernet)."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "key_name" {
  description = "Optional EC2 key pair name."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
