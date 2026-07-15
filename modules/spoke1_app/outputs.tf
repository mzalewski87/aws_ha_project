###############################################################################
# modules/spoke1_app — outputs
###############################################################################

output "instance_id" {
  description = "Apache EC2 instance ID."
  value       = aws_instance.apache.id
}

output "private_ip" {
  description = "Apache private IP (FW DNAT target)."
  value       = aws_instance.apache.private_ip
}

output "security_group_id" {
  description = "Apache security group ID."
  value       = aws_security_group.app.id
}
