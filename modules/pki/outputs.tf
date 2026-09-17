###############################################################################
# modules/pki — outputs
###############################################################################

output "root_ca_instance_id" {
  description = "Offline root CA instance ID (SSM target; stopped once the issuing CA is signed)."
  value       = aws_instance.root_ca.id
}

output "sub_ca_instance_id" {
  description = "Enterprise issuing CA instance ID (SSM target)."
  value       = aws_instance.sub_ca.id
}

output "root_ca_private_ip" {
  description = "Offline root CA private IP."
  value       = aws_instance.root_ca.private_ip
}

output "sub_ca_private_ip" {
  description = "Issuing CA private IP — also the AIA/CDP host."
  value       = aws_instance.sub_ca.private_ip
}

output "sub_ca_hostname" {
  description = "Issuing CA hostname as AD will see it (EC2 default naming)."
  value       = "ip-${replace(aws_instance.sub_ca.private_ip, ".", "-")}"
}
