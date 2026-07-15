###############################################################################
# Phase 2a — outputs
###############################################################################

output "template_stack_name" {
  description = "Panorama template stack (FW init-cfg tplname=)."
  value       = module.panorama_config.template_stack_name
}

output "device_group_name" {
  description = "Panorama device group (FW init-cfg dgname=)."
  value       = module.panorama_config.device_group_name
}

output "vm_auth_key_file" {
  description = "Path of the generated vm-auth-key tfvars consumed by Phase 1b."
  value       = var.vm_auth_key_output_path
}
