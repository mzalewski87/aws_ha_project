###############################################################################
# modules/global_accelerator — outputs
###############################################################################

output "accelerator_dns_name" {
  description = "GA DNS name (point the portal FQDN CNAME here)."
  value       = aws_globalaccelerator_accelerator.this.dns_name
}

output "accelerator_static_ips" {
  description = "The 2 static anycast IPs (the client keeps these forever)."
  value       = aws_globalaccelerator_accelerator.this.ip_sets
}
