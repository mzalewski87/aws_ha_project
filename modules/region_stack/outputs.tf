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
  value       = !local.panorama_mode ? null : (var.create_panorama ? module.panorama[0].panorama_private_ip : var.panorama_private_ip)
  description = "Panorama IP serving this region (null in management_mode = scm)."
}

output "panorama_instance_id" {
  value       = var.create_panorama && local.panorama_mode ? module.panorama[0].panorama_instance_id : null
  description = "Panorama instance ID (primary region, panorama mode only)."
}

output "ssm_jumphost_instance_id" {
  value = !var.create_panorama ? null : (
    local.panorama_mode ? module.panorama[0].jumphost_instance_id : module.ssm_jumphost[0].instance_id
  )
  description = "SSM jump host instance ID (primary region only; both management modes)."
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

output "app_cloudfront_hosted_zone_id" {
  description = "Route53 hosted-zone ID of the app CloudFront distribution (for alias records)."
  value       = var.create_app ? module.cloudfront[0].distribution_hosted_zone_id : ""
}

output "app_instance_id" {
  description = "Apache EC2 instance ID (SSM target for reading the install log)."
  value       = var.create_app ? module.spoke1_app[0].instance_id : ""
}

output "pki_root_ca_instance_id" {
  description = "Offline root CA instance ID (empty when the PKI is disabled)."
  value       = var.create_dc && var.create_pki ? module.pki[0].root_ca_instance_id : ""
}

output "pki_sub_ca_instance_id" {
  description = "Enterprise issuing CA instance ID (empty when the PKI is disabled)."
  value       = var.create_dc && var.create_pki ? module.pki[0].sub_ca_instance_id : ""
}

output "guacamole_alb_dns_name" {
  value       = local.create_guac ? module.guacamole[0].alb_dns_name : null
  description = "Guacamole ALB DNS name (alias target for the public hostname)."
}

output "guacamole_alb_zone_id" {
  value       = local.create_guac ? module.guacamole[0].alb_zone_id : null
  description = "Guacamole ALB hosted-zone id (Route53 alias)."
}

output "guacamole_admin_secret_arn" {
  value       = local.create_guac ? module.guacamole[0].admin_secret_arn : null
  description = "Secrets Manager ARN holding the Guacamole admin credentials."
}

output "panel_alb_dns_name" {
  value       = local.create_panel ? module.panel[0].alb_dns_name : null
  description = "Admin panel ALB DNS name (alias target for the public hostname)."
}

output "panel_alb_zone_id" {
  value       = local.create_panel ? module.panel[0].alb_zone_id : null
  description = "Admin panel ALB hosted-zone id (Route53 alias)."
}

output "panel_secret_arn" {
  value       = local.create_panel ? module.panel[0].secret_arn : null
  description = "Secrets Manager ARN with the panel's read-only firewall admin password."
}

output "fw_instance_ids" {
  value       = module.firewall.instance_ids
  description = "Firewall EC2 instance ids by fw name (panel failover tests in another region)."
}

output "fw_untrust_eni_ids" {
  value       = module.firewall.untrust_eni_ids
  description = "Firewall untrust ENI ids by fw name (panel topology: who holds the EIP)."
}

output "fw_trust_eni_ids" {
  value       = module.firewall.trust_eni_ids
  description = "Firewall trust ENI ids by fw name (panel topology: where the routes point)."
}

output "mgmt_panel_route_table_ids" {
  value       = local.create_panel ? module.vpc_mgmt.route_table_ids_by_role["panel"] : []
  description = "Panel subnet route tables (per AZ) — need a route to a remote region's firewall mgmt."
}
