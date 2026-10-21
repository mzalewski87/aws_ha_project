output "alb_dns_name" {
  value = aws_lb.this.dns_name
}
output "alb_zone_id" {
  value = aws_lb.this.zone_id
}
output "instance_id" {
  value = aws_instance.guac.id
}
output "private_ip" {
  value = aws_instance.guac.private_ip
}
output "security_group_id" {
  description = "Host SG — the RDP target's SG should allow 3389 from this."
  value       = aws_security_group.host.id
}
output "admin_secret_arn" {
  description = "Secrets Manager secret holding the Guacamole admin password."
  value       = aws_secretsmanager_secret.admin.arn
}
