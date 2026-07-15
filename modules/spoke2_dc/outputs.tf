###############################################################################
# modules/spoke2_dc — outputs
###############################################################################

output "instance_id" {
  description = "Windows DC EC2 instance ID."
  value       = aws_instance.dc.id
}

output "private_ip" {
  description = "DC private IP (domain DNS server)."
  value       = aws_instance.dc.private_ip
}

output "password_data" {
  description = "Encrypted Administrator password (decrypt with the key pair: aws ec2 get-password-data)."
  value       = aws_instance.dc.password_data
  sensitive   = true
}
