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

  # Same rule as the root version_guard, but here it also holds under -target: a targeted
  # plan skips terraform_data.version_guard, yet still renders this output. Seen live: a
  # targeted root plan without the TF_VAR_* secrets loaded wanted to blank the PIN in the
  # user_data of all four running firewalls (an in-place user_data change = stop/start).
  precondition {
    condition     = var.management_mode != "scm" || (var.vm_series_auto_registration_pin_id != "" && var.vm_series_auto_registration_pin_value != "")
    error_message = "management_mode = \"scm\" needs the registration PIN (fw_registration_pin_id / _value). Empty usually means the secrets (TF_VAR_*) were not loaded before plan."
  }
}
