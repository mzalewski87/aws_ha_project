###############################################################################
# modules/transit_gateway — outputs
###############################################################################

output "transit_gateway_id" {
  description = "Transit Gateway ID."
  value       = aws_ec2_transit_gateway.this.id
}

output "attachment_ids" {
  description = "VPC attachment IDs keyed by role name."
  value       = { for k, a in aws_ec2_transit_gateway_vpc_attachment.this : k => a.id }
}

output "security_route_table_id" {
  description = "TGW route table associated with the security (inspection) VPC."
  value       = aws_ec2_transit_gateway_route_table.security.id
}

output "spoke_route_table_id" {
  description = "TGW route table associated with the management/spoke VPCs."
  value       = aws_ec2_transit_gateway_route_table.spoke.id
}
