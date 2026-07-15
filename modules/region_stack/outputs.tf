###############################################################################
# modules/region_stack — outputs
###############################################################################

output "transit_gateway_id" {
  value       = module.transit_gateway.transit_gateway_id
  description = "This region's TGW ID (for cross-region peering)."
}

output "tgw_spoke_route_table_id" {
  value       = module.transit_gateway.spoke_route_table_id
  description = "TGW spoke route table (add cross-region routes here)."
}

output "tgw_security_route_table_id" {
  value       = module.transit_gateway.security_route_table_id
  description = "TGW security route table (peering attachment associates here)."
}

output "tgw_security_attachment_id" {
  value       = module.transit_gateway.attachment_ids["security"]
  description = "Security VPC TGW attachment ID (cross-region delivery target)."
}

output "security_vpc_cidr" {
  value = var.security_vpc_cidr
}

output "mgmt_vpc_cidr" {
  value = var.mgmt_vpc_cidr
}

output "fw_public_eip" {
  value       = module.firewall.public_eip
  description = "FW public EIP (regional GP/portal entry)."
}

output "fw_public_eip_allocation_id" {
  value       = module.firewall.public_eip_allocation_id
  description = "FW public EIP allocation ID (Global Accelerator endpoint)."
}

output "fw_mgmt_private_ips" {
  value       = module.firewall.mgmt_private_ips
  description = "FW mgmt IPs (serial-registration script)."
}

output "fw_ha2_private_ips" {
  value       = module.firewall.ha2_private_ips
  description = "FW HA2 ENI IPs (HA2_IP input for scripts/configure-ha.sh)."
}

output "panorama_private_ip" {
  value       = var.create_panorama ? module.panorama[0].panorama_private_ip : var.panorama_private_ip
  description = "Panorama IP serving this region."
}

output "panorama_instance_id" {
  value       = var.create_panorama ? module.panorama[0].panorama_instance_id : null
  description = "Panorama instance ID (primary region only)."
}

output "ssm_jumphost_instance_id" {
  value       = var.create_panorama ? module.panorama[0].jumphost_instance_id : null
  description = "SSM jump host instance ID (primary region only)."
}

output "app_cloudfront_domain" {
  value       = var.create_app ? module.cloudfront[0].distribution_domain_name : null
  description = "App CloudFront domain (when create_app)."
}

output "app_nlb_dns_name" {
  value       = var.create_app ? module.loadbalancer[0].nlb_dns_name : null
  description = "App NLB DNS (when create_app)."
}

output "dc_instance_id" {
  value       = var.create_dc ? module.spoke2_dc[0].instance_id : null
  description = "Windows DC instance ID (when create_dc) — target for `aws ssm start-session`."
}

output "dc_private_ip" {
  value       = var.create_dc ? module.spoke2_dc[0].private_ip : null
  description = "Windows DC private IP (domain DNS server; LDAP server address for GP auth)."
}

# --- Route tables for cross-region (peering) wiring --------------------------
output "security_mgmt_route_table_ids" {
  value       = module.vpc_security.route_table_ids_by_role["mgmt"]
  description = "Security VPC FW-mgmt subnet route tables (per AZ) — add remote-Panorama routes here."
}

output "mgmt_panorama_route_table_ids" {
  value       = module.vpc_mgmt.route_table_ids_by_role["panorama"]
  description = "Mgmt VPC Panorama subnet route tables (per AZ) — add remote-region routes here."
}

output "mgmt_ssm_route_table_ids" {
  value       = module.vpc_mgmt.route_table_ids_by_role["ssm"]
  description = "Mgmt VPC SSM jump-host subnet route tables (per AZ) — need remote-region routes so the jump host can SSH remote FWs for HA config (scripts/configure-ha.sh)."
}

output "http_redirect_alb_arn" {
  value       = var.enable_http_redirect ? module.http_redirect_alb[0].alb_arn : null
  description = "HTTP->HTTPS redirect ALB ARN — register as the Global Accelerator :80 endpoint. Null unless enable_http_redirect."
}
