output "alb_dns_name" {
  value = aws_lb.this.dns_name
}
output "alb_zone_id" {
  value = aws_lb.this.zone_id
}
output "instance_ids" {
  value = aws_instance.panel[*].id
}
output "security_group_id" {
  description = "Host SG — the DC's SG should allow LDAP (TCP 389) from the panel subnets."
  value       = aws_security_group.host.id
}
output "secret_arn" {
  description = "Secrets Manager secret with the panel's session key and the read-only firewall admin password."
  value       = aws_secretsmanager_secret.panel.arn
}
