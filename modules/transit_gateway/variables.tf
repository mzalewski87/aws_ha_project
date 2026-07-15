###############################################################################
# modules/transit_gateway — variables
#
# Centralized hub replacing Azure VNet peering + the internal-LB "HA ports"
# mechanism (which has NO AWS analog). ADR D5. appliance_mode on the security
# VPC attachment is load-bearing: it guarantees cross-AZ flow symmetry, which is
# why a single PAN-OS virtual router suffices (verified — replaces Azure dual-VR).
###############################################################################

variable "name_prefix" {
  description = "Name prefix for TGW resources, e.g. \"awsha-a\"."
  type        = string
}

variable "amazon_side_asn" {
  description = "Private ASN for the TGW Amazon side."
  type        = number
  default     = 64512
}

variable "attachments" {
  description = <<-EOT
    VPC attachments keyed by role name (e.g. "security", "mgmt", "spoke1",
    "spoke2"). Exactly one attachment should set associate_with = "security"
    (the inspection VPC); it gets appliance_mode enabled and is associated with
    the security route table. All others associate with the spoke route table.
  EOT
  type = map(object({
    vpc_id         = string
    vpc_cidr       = string
    subnet_ids     = list(string) # dedicated tgw-attach subnets (one per AZ)
    associate_with = string       # "security" | "spoke"
  }))

  validation {
    condition     = length([for a in var.attachments : a if a.associate_with == "security"]) == 1
    error_message = "Exactly one attachment must have associate_with = \"security\"."
  }
}

variable "tgw_routes_in_vpc" {
  description = <<-EOT
    Routes to add inside VPC route tables pointing at the TGW (next hop =
    transit_gateway_id). Used for the management-plane path (Panorama <-> FW
    mgmt) that must NOT traverse the FW dataplane. Keyed by a STATIC id
    (e.g. "mgmt-panorama-0") so for_each keys are known at plan time — the
    route_table_id value may be unknown until apply.
  EOT
  type = map(object({
    route_table_id         = string
    destination_cidr_block = string
  }))
  default = {}
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
