###############################################################################
# modules/panorama — outputs
###############################################################################

output "panorama_instance_id" {
  description = "Panorama EC2 instance ID."
  value       = aws_instance.panorama.id
}

output "panorama_private_ip" {
  description = "Panorama private IP (init-cfg panorama-server= for the FWs)."
  value       = var.panorama_private_ip
}

output "panorama_ami_id" {
  description = "Resolved Panorama AMI ID."
  value       = aws_instance.panorama.ami
}

output "log_volume_id" {
  description = "Panorama log-collection EBS volume ID."
  value       = aws_ebs_volume.panorama_logs.id
}

output "jumphost_instance_id" {
  description = "SSM jump host instance ID (target for AWS-StartPortForwardingSessionToRemoteHost in Phase 2a)."
  value       = aws_instance.jumphost.id
}

output "panorama_security_group_id" {
  description = "Panorama security group ID."
  value       = aws_security_group.panorama.id
}
