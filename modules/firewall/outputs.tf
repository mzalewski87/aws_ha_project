###############################################################################
# modules/firewall — outputs
###############################################################################

output "instance_ids" {
  description = "FW EC2 instance IDs keyed by fw name."
  value       = { for k, i in aws_instance.fw : k => i.id }
}

output "mgmt_private_ips" {
  description = "FW mgmt private IPs (for the Phase 2b serial-registration script)."
  value       = { for fw in local.fw_names : fw => tolist(aws_network_interface.fw["${fw}-mgmt"].private_ips)[0] }
}

output "ha2_private_ips" {
  description = "FW HA2 ENI private IP per fw — the HA2_IP input for scripts/configure-ha.sh."
  value       = { for fw in local.fw_names : fw => tolist(aws_network_interface.fw["${fw}-ha2"].private_ips)[0] }
}

output "trust_eni_ids" {
  description = "FW trust ENI IDs keyed by fw name."
  value       = { for fw in local.fw_names : fw => aws_network_interface.fw["${fw}-trust"].id }
}

output "untrust_eni_ids" {
  description = "FW untrust ENI IDs keyed by fw name."
  value       = { for fw in local.fw_names : fw => aws_network_interface.fw["${fw}-untrust"].id }
}

output "untrust_primary_ips" {
  description = "FW untrust primary private IPs (LB-sandwich target registration)."
  value       = { for fw in local.fw_names : fw => tolist(aws_network_interface.fw["${fw}-untrust"].private_ips)[0] }
}

# Initial active FW trust ENI — the dataplane next hop for TGW inspection routes.
# The HA plugin rewrites these routes to the peer on failover (ec2:ReplaceRoute).
output "active_trust_eni_id" {
  description = "Trust ENI of the initially-active FW (fw1) — next hop for inspection routes."
  value       = aws_network_interface.fw["fw1-trust"].id
}

output "public_eip" {
  description = "Public EIP (GP portal/gateway + outbound SNAT)."
  value       = aws_eip.fw_public.public_ip
}

output "public_eip_allocation_id" {
  description = "Allocation ID of the public EIP (endpoint for Global Accelerator in Phase R2)."
  value       = aws_eip.fw_public.id
}

output "floating_ip" {
  description = "Untrust floating private IP carrying the public EIP (moves on failover)."
  value       = local.floating_ip
}
