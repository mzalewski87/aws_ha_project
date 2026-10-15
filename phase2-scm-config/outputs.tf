output "folder" {
  description = "SCM folder holding the firewalls and their config."
  value       = scm_folder.fw.name
}

output "configured_devices" {
  description = "Serials that received per-device address overrides."
  value       = sort(keys(var.fw_devices))
}
