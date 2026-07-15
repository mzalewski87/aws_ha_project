###############################################################################
# modules/panorama_config — outputs
###############################################################################

output "template_name" {
  value       = panos_template.tpl.name
  description = "Panorama template name."
}

output "template_stack_name" {
  value       = panos_template_stack.stack.name
  description = "Panorama template stack name."
}

output "device_group_name" {
  value       = panos_device_group.dg.name
  description = "Panorama device group name."
}

output "gp_portal_name" {
  value       = var.enable_globalprotect ? panos_globalprotect_portal.portal[0].name : null
  description = "GlobalProtect portal name (null when GP disabled)."
}
