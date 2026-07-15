###############################################################################
# modules/custom_domain — outputs
###############################################################################

output "name_servers" {
  description = "Route53 name servers for the subdomain zone. DELEGATE the subdomain to these once, at the parent domain's registrar/DNS (create NS records for the subdomain pointing here). Until you do, the records + Let's Encrypt DNS-01 won't resolve publicly."
  value       = local.on ? aws_route53_zone.sub[0].name_servers : []
}

output "zone_id" {
  description = "Route53 hosted zone ID for the subdomain."
  value       = local.on ? aws_route53_zone.sub[0].zone_id : ""
}

output "portal_fqdn" {
  description = "Portal FQDN GlobalProtect users enter (resolves to the Global Accelerator anycast IPs)."
  value       = local.portal_fqdn
}

output "gateway_fqdns" {
  description = "Per-region gateway FQDNs (use these in the portal external-gateway list)."
  value       = local.on ? { for k, v in var.gateway_records : k => "${k}.${var.subdomain_zone}" } : {}
}

output "cert_pem" {
  description = "Let's Encrypt leaf certificate PEM (empty unless cert_mode = letsencrypt). Feed to phase2 gp_server_cert_pem."
  value       = local.le ? acme_certificate.wildcard[0].certificate_pem : ""
  sensitive   = true
}

output "cert_key_pem" {
  description = "Private key PEM for the Let's Encrypt cert. Feed to phase2 gp_server_key_pem."
  value       = local.le ? acme_certificate.wildcard[0].private_key_pem : ""
  sensitive   = true
}

output "cert_chain_pem" {
  description = "Issuer (intermediate) chain PEM for the Let's Encrypt cert."
  value       = local.le ? acme_certificate.wildcard[0].issuer_pem : ""
  sensitive   = true
}
