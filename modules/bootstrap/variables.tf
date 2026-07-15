###############################################################################
# modules/bootstrap — variables
#
# Renders each FW's init-cfg.txt (delivered as base64 user-data over IMDSv2 in
# Phase 1b — the AWS analog of Azure custom_data, ADR D7) and creates the IAM
# instance profile the FWs need (PAN-OS AWS HA plugin EC2 permissions + SSM).
###############################################################################

variable "name_prefix" {
  description = "Name prefix for IAM + rendered artifacts, e.g. \"awsha-a\"."
  type        = string
}

variable "fw_hostnames" {
  description = "Ordered list of FW hostnames to render init-cfg for (e.g. [\"fw1\", \"fw2\"])."
  type        = list(string)
  default     = ["fw1", "fw2"]
}

# --- init-cfg / Panorama wiring (parity with Azure bootstrap fields) ---------

variable "panorama_server" {
  description = "Panorama private IP (init-cfg panorama-server=)."
  type        = string
}

variable "panorama_template_stack" {
  description = "Panorama Template Stack name (init-cfg tplname=)."
  type        = string
}

variable "panorama_device_group" {
  description = "Panorama Device Group name (init-cfg dgname=)."
  type        = string
}

variable "panorama_vm_auth_key" {
  description = "VM auth key from Panorama (Phase 2a generates it). Empty = FW boots but does not auto-register."
  type        = string
  default     = ""
  sensitive   = true
}

variable "fw_auth_code" {
  description = "VM-Series BYOL license auth code (init-cfg authcodes=)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "vm_series_auto_registration_pin_id" {
  description = "CSP auto-registration PIN ID (device-cert fetch on first boot). Shared across FWs."
  type        = string
  default     = ""
  sensitive   = true
}

variable "vm_series_auto_registration_pin_value" {
  description = "Companion PIN value for vm_series_auto_registration_pin_id."
  type        = string
  default     = ""
  sensitive   = true
}

variable "dns_primary" {
  description = "Primary DNS for the FW mgmt plane. AWS VPC resolver is <vpc-cidr-base>+2 (no Azure magic 168.63.129.16)."
  type        = string
}

variable "dns_secondary" {
  description = "Secondary DNS (public resolver)."
  type        = string
  default     = "1.1.1.1"
}

# --- IAM / bootstrap source options -----------------------------------------

variable "ha_failover_mode" {
  description = <<-EOT
    Which HA-plugin IAM permissions to grant:
      - "secondary_ip" : same-AZ secondary-IP + EIP move AND route-table
                         failover (superset; recommended default).
      - "interface"    : minimal ENI-move-only permission set.
    Verified against the PAN-OS AWS HA "IAM roles for HA" doc.
  EOT
  type        = string
  default     = "secondary_ip"

  validation {
    condition     = contains(["secondary_ip", "interface"], var.ha_failover_mode)
    error_message = "ha_failover_mode must be \"secondary_ip\" or \"interface\"."
  }
}

variable "enable_s3_bootstrap" {
  description = "Reserved: grant s3:GetObject/ListBucket for an S3 bootstrap bucket (ADR D7 — only if a bootstrap.xml / content bundle is needed). Default off (inline user-data)."
  type        = bool
  default     = false
}

variable "s3_bootstrap_bucket_arn" {
  description = "ARN of the S3 bootstrap bucket (used only when enable_s3_bootstrap = true)."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
