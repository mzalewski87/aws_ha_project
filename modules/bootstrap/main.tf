###############################################################################
# modules/bootstrap — main
#
# Renders init-cfg.txt per firewall. The base64 of each rendered file is the
# EC2 user-data consumed by the firewall module in Phase 1b (read over IMDSv2 at
# first boot — the AWS analog of Azure custom_data). Rendered copies are also
# written to disk for troubleshooting (parity with the Azure bootstrap module).
#
# No Managed Identity here — that is an Azure concept; on AWS the equivalent is
# the IAM instance profile in iam.tf.
###############################################################################

terraform {
  required_providers {
    aws   = { source = "hashicorp/aws" }
    local = { source = "hashicorp/local" }
  }
}

locals {
  init_cfg = {
    for name in var.fw_hostnames : name => templatefile("${path.module}/templates/init-cfg.txt.tpl", {
      hostname                              = name
      panorama_server                       = var.panorama_server
      panorama_template_stack               = var.panorama_template_stack
      panorama_device_group                 = var.panorama_device_group
      panorama_vm_auth_key                  = var.panorama_vm_auth_key
      authcodes                             = var.fw_auth_code
      vm_series_auto_registration_pin_id    = var.vm_series_auto_registration_pin_id
      vm_series_auto_registration_pin_value = var.vm_series_auto_registration_pin_value
      dns_primary                           = var.dns_primary
      dns_secondary                         = var.dns_secondary
    })
  }
}

# Rendered copies on disk (inspection only; the authoritative value is the
# base64 user-data output). Kept out of VCS via .gitignore in the repo root.
resource "local_file" "init_cfg" {
  for_each = local.init_cfg
  content  = each.value
  filename = "${path.module}/rendered/${each.key}-init-cfg.txt"
}
