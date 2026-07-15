###############################################################################
# Root outputs. Region A is always present; Region B outputs are null until
# var.enable_region_b. Handoffs for the phased workflow + quick references.
###############################################################################

# --- Panorama / management (Phase 2a) ---------------------------------------
output "panorama_private_ip" {
  description = "Panorama private IP (panos provider target via the SSM tunnel)."
  value       = module.region_a.panorama_private_ip
}

output "panorama_instance_id" {
  description = "Panorama EC2 instance ID (Region A)."
  value       = module.region_a.panorama_instance_id
}

output "ssm_jumphost_instance_id" {
  description = "SSM jump host instance ID — start the Phase 2a port-forward against this."
  value       = module.region_a.ssm_jumphost_instance_id
}

# --- Firewalls (Phase 2b) ---------------------------------------------------
output "fw_mgmt_private_ips" {
  description = "VM-Series mgmt IPs by region (serial-registration script)."
  value = {
    region_a = module.region_a.fw_mgmt_private_ips
    region_b = var.enable_region_b ? module.region_b[0].fw_mgmt_private_ips : null
  }
}

output "fw_public_eips" {
  description = "Per-region FW public EIPs (GP portal/gateway entry points)."
  value = {
    region_a = module.region_a.fw_public_eip
    region_b = var.enable_region_b ? module.region_b[0].fw_public_eip : null
  }
}

# --- App ingress ------------------------------------------------------------
output "app_cloudfront_domain" {
  description = "CloudFront domain in front of the Region A app."
  value       = module.region_a.app_cloudfront_domain
}

# --- Windows DC (Phase 3) ----------------------------------------------------
output "dc_instance_id" {
  description = "Windows DC instance ID (Region A) — target for `aws ssm start-session` (RDP port-forward + RunCommand)."
  value       = module.region_a.dc_instance_id
}

output "dc_private_ip" {
  description = "Windows DC private IP (Region A) — domain DNS server / GP LDAP server address."
  value       = module.region_a.dc_private_ip
}

output "fw_ha2_private_ips" {
  description = "FW HA2 ENI private IPs by region/fw — the HA2_IP input for scripts/configure-ha.sh (native HA setup)."
  value = {
    region_a = module.region_a.fw_ha2_private_ips
    region_b = var.enable_region_b ? module.region_b[0].fw_ha2_private_ips : null
  }
}

output "dc_instance_id_b" {
  description = "Windows DC instance ID (Region B additional DC) — SSM target for replication checks."
  value       = var.enable_region_b && var.region_b_create_dc ? module.region_b[0].dc_instance_id : null
}

output "dc_private_ip_b" {
  description = "Windows DC private IP (Region B additional DC) — add to phase2 gp_ldap_extra_server_ips + gp_dns_servers for region-outage LDAP failover."
  value       = var.enable_region_b && var.region_b_create_dc ? module.region_b[0].dc_private_ip : null
}

# --- Global entry (Phase R2) ------------------------------------------------
output "global_accelerator_dns_name" {
  description = "Global Accelerator DNS name (portal FQDN CNAME target)."
  value       = var.enable_global_accelerator ? module.global_accelerator[0].accelerator_dns_name : null
}

output "global_accelerator_static_ips" {
  description = "Global Accelerator static anycast IPs."
  value       = var.enable_global_accelerator ? module.global_accelerator[0].accelerator_static_ips : null
}

# --- Custom domain (Phase GP, optional) -------------------------------------
output "custom_domain_name_servers" {
  description = "DELEGATE the subdomain to these NS at your parent domain (one-time), then the portal/gateway FQDNs + Let's Encrypt DNS-01 resolve publicly. Empty unless enable_custom_domain."
  value       = var.enable_custom_domain ? module.custom_domain[0].name_servers : []
}

output "custom_domain_portal_fqdn" {
  description = "Portal FQDN GlobalProtect users enter."
  value       = var.enable_custom_domain ? module.custom_domain[0].portal_fqdn : null
}

output "custom_domain_gateway_fqdns" {
  description = "Per-region gateway FQDNs — use these in phase2 gp_external_gateways."
  value       = var.enable_custom_domain ? module.custom_domain[0].gateway_fqdns : {}
}

output "custom_domain_cert_pem" {
  description = "Let's Encrypt cert PEM (leaf + chain) — feed to phase2 gp_server_cert_pem. Empty unless cert_mode = letsencrypt."
  value       = var.enable_custom_domain && var.custom_domain_cert_mode == "letsencrypt" ? "${module.custom_domain[0].cert_pem}${module.custom_domain[0].cert_chain_pem}" : ""
  sensitive   = true
}

output "custom_domain_cert_key_pem" {
  description = "Let's Encrypt private key PEM — feed to phase2 gp_server_key_pem."
  value       = var.enable_custom_domain && var.custom_domain_cert_mode == "letsencrypt" ? module.custom_domain[0].cert_key_pem : ""
  sensitive   = true
}

# --- Network ----------------------------------------------------------------
output "transit_gateway_ids" {
  description = "TGW IDs by region."
  value = {
    region_a = module.region_a.transit_gateway_id
    region_b = var.enable_region_b ? module.region_b[0].transit_gateway_id : null
  }
}
