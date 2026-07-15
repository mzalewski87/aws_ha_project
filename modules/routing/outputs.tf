###############################################################################
# modules/routing — outputs
###############################################################################

output "spoke_default_route_id" {
  description = "TGW spoke default-route ID (0.0.0.0/0 -> security attachment)."
  value       = aws_ec2_transit_gateway_route.spoke_default_to_security.id
}
