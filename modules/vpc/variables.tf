###############################################################################
# modules/vpc — variables
#
# Region-agnostic VPC building block. Instantiated once per VPC role
# (security / management / spoke). All region/AZ/CIDR values are passed in from
# the root so the module hardcodes nothing (multi-region-ready, ADR D2).
###############################################################################

variable "name_prefix" {
  description = "Name prefix for all resources, e.g. \"awsha-a-security\"."
  type        = string
}

variable "vpc_cidr" {
  description = "Primary IPv4 CIDR for this VPC."
  type        = string
}

variable "azs" {
  description = "Ordered list of Availability Zone names. Subnet CIDR lists are index-aligned to this list."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "Provide at least two AZs for HA / multi-AZ layout."
  }
}

variable "subnets" {
  description = <<-EOT
    Map of subnet groups for this VPC, keyed by role name (e.g. "mgmt",
    "untrust", "trust", "ha2", "panorama", "ssm", "public", "workload",
    "tgw"). Each group is spread across all AZs; `cidrs` is index-aligned to
    `var.azs`.

    kind controls the AZ route table default route:
      - "public"   : 0.0.0.0/0 -> Internet Gateway (also hosts the per-AZ NAT GW)
      - "private"  : 0.0.0.0/0 -> NAT Gateway in the same AZ
      - "isolated" : no default route (local only; TGW/dataplane routes added
                     elsewhere) — used for trust/ha2/tgw-attach/spoke workloads
  EOT
  type = map(object({
    kind                    = string
    cidrs                   = list(string)
    map_public_ip_on_launch = optional(bool, false)
  }))

  validation {
    condition     = alltrue([for s in var.subnets : contains(["public", "private", "isolated"], s.kind)])
    error_message = "Each subnet group kind must be one of: public, private, isolated."
  }
}

variable "create_igw" {
  description = "Create an Internet Gateway (needed when the VPC has public subnets)."
  type        = bool
  default     = false
}

variable "create_nat" {
  description = "Create one NAT Gateway per AZ (in the public subnet of that AZ). Requires a \"public\"-kind subnet group."
  type        = bool
  default     = false
}

variable "security_groups" {
  description = <<-EOT
    Security groups to create in this VPC, keyed by short name (referenced by
    consumers via the sg_ids output). Egress defaults to allow-all when omitted.
  EOT
  type = map(object({
    description = optional(string, "Managed by Terraform")
    ingress = optional(list(object({
      description = optional(string, "")
      from_port   = number
      to_port     = number
      protocol    = string
      cidr_blocks = optional(list(string), [])
    })), [])
    egress = optional(list(object({
      description = optional(string, "")
      from_port   = number
      to_port     = number
      protocol    = string
      cidr_blocks = optional(list(string), ["0.0.0.0/0"])
    })), [])
  }))
  default = {}
}

variable "tags" {
  description = "Extra tags merged onto every resource (provider default_tags apply on top)."
  type        = map(string)
  default     = {}
}
