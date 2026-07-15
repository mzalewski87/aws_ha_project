###############################################################################
# modules/routing — variables
#
# Phase 1b dataplane routing that goes live once the FWs exist. Replaces the
# Azure UDR "0.0.0.0/0 -> internal LB" pattern with:
#   spoke workload -> TGW -> security VPC tgw-attach -> FW trust ENI (inspect)
#   FW trust ENI  -> TGW -> back to spokes (appliance-mode symmetry)
# The FW-trust next hop is rewritten to the peer by the HA plugin on failover.
###############################################################################

variable "transit_gateway_id" {
  description = "Transit Gateway ID."
  type        = string
}

variable "tgw_spoke_route_table_id" {
  description = "TGW spoke route table ID (gets the default route to the security attachment)."
  type        = string
}

variable "tgw_security_attachment_id" {
  description = "TGW attachment ID of the security VPC (inspection next hop)."
  type        = string
}

variable "active_trust_eni_id" {
  description = "Trust ENI of the initially-active FW (inspection next hop inside the security VPC)."
  type        = string
}

variable "security_tgw_attach_route_table_ids" {
  description = "Security VPC tgw-attach subnet route table IDs, keyed by static \"<role>-<az>\" (values may be unknown at plan). Get 0.0.0.0/0 -> FW trust ENI."
  type        = map(string)
}

variable "security_trust_route_table_ids" {
  description = "Security VPC trust subnet route table IDs, keyed by static \"<role>-<az>\". Get inspected_supernet -> TGW (FW return path)."
  type        = map(string)
}

variable "spoke_workload_route_table_ids" {
  description = "Spoke workload subnet route table IDs (all spokes, all AZs), keyed by static id. Get 0.0.0.0/0 -> TGW."
  type        = map(string)
}

variable "inspected_supernet" {
  description = "Internal supernet the FW returns toward the spokes/mgmt via TGW."
  type        = string
  default     = "10.0.0.0/8"
}

variable "tags" {
  description = "Extra tags (unused by routes; kept for interface parity)."
  type        = map(string)
  default     = {}
}
