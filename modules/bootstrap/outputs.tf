###############################################################################
# modules/bootstrap — outputs
###############################################################################

output "instance_profile_name" {
  description = "IAM instance profile name to attach to the FW instances (Phase 1b)."
  value       = aws_iam_instance_profile.fw.name
}

output "instance_profile_arn" {
  description = "IAM instance profile ARN."
  value       = aws_iam_instance_profile.fw.arn
}

output "fw_role_name" {
  description = "IAM role name backing the FW instance profile."
  value       = aws_iam_role.fw.name
}

# base64 user-data per FW hostname, consumed by the firewall module in Phase 1b.
output "user_data" {
  description = "Map of FW hostname => base64-encoded init-cfg (EC2 user-data)."
  value       = { for name, content in local.init_cfg : name => base64encode(content) }
  sensitive   = true
}
