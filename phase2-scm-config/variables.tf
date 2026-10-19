variable "scm_tsg_id" {
  description = "Strata Cloud Manager tenant service group (TSG) ID."
  type        = string
}

variable "scm_client_id" {
  description = "Service-account client ID (<name>@<tsg>.iam.panserviceaccount.com)."
  type        = string
}

variable "scm_client_secret" {
  description = "Service-account client secret."
  type        = string
  sensitive   = true
}

# ---- Folder / tenant layout ---------------------------------------------------
variable "folder_name" {
  description = "SCM folder that holds this deployment's firewalls and config. Created here; pre-existing folders are never touched."
  type        = string
  default     = "AWS-HA-Transit"
}

variable "parent_folder" {
  description = "Parent of the new folder in the SCM folder tree. NGFW folders live under the \"ngfw-shared\" container; SCM rejects the predefined \"All\" container as a parent (DC_0001). The folder still inherits snippets from All and ngfw-shared."
  type        = string
  default     = "ngfw-shared"
}

# ---- Per-device values (handoff from scripts/scm-onboard-fw.sh) ---------------
variable "fw_devices" {
  description = "Device serial => its own dataplane addresses (CIDR). Written to fw_devices.auto.tfvars.json by scripts/scm-onboard-fw.sh once the firewalls have registered. Empty = folder defaults only."
  type = map(object({
    trust_ip   = string
    untrust_ip = string
  }))
  default = {}
}

variable "trust_ip_default" {
  description = "Folder-level default for $trust_ip (overridden per device)."
  type        = string
  default     = "10.10.20.11/24"
}

variable "untrust_ip_default" {
  description = "Folder-level default for $untrust_ip (overridden per device)."
  type        = string
  default     = "10.10.10.11/24"
}

variable "untrust_floating_cidr" {
  description = "Shared floating untrust address as a /32 (GP portal/gateway + SNAT bind here; the EIP follows the active unit)."
  type        = string
  default     = "10.10.10.100/32"
}

variable "trust_gateway_ip" {
  description = "Trust-subnet gateway (.1 of the trust subnet) for the internal supernet route."
  type        = string
  default     = "10.10.20.1"
}

variable "untrust_gateway_ip" {
  description = "Untrust-subnet gateway (.1 of the untrust subnet) for the default route."
  type        = string
  default     = "10.10.10.1"
}

variable "mgmt_permitted_cidrs" {
  description = "Sources allowed on the dataplane management profile (security + mgmt VPC for health checks/SSM hop)."
  type        = list(string)
  default     = ["10.10.0.0/16", "10.11.0.0/16"]
}

# ---- Policy inputs (same meaning as phase2-panorama-config) -------------------
variable "app_dnat_public_ip" {
  description = "Untrust floating VIP that inbound app traffic (CloudFront -> NLB) targets (pre-NAT destination)."
  type        = string
  default     = "10.10.10.100"
}

variable "app_private_ip" {
  description = "Apache backend IP that inbound-app-dnat translates to."
  type        = string
  default     = "10.12.0.10"
}

variable "gp_local_ips" {
  description = "Floating IP(s) the GP portal/gateway bind to, one per region."
  type        = list(string)
  default     = ["10.10.10.100"]
}

variable "guac_rdp_source_cidrs" {
  description = "Guacamole subnet(s) allowed RDP to the DC through the firewalls. [] disables the rule."
  type        = list(string)
  default     = ["10.11.20.0/23"]
}

variable "dc_private_ip" {
  description = "Domain controller IP (destination of the Guacamole RDP rule)."
  type        = string
  default     = "10.13.0.10"
}

variable "internal_supernet" {
  description = "Internal supernet routed back toward the TGW via the trust interface (covers mgmt, spokes and the Guacamole subnet)."
  type        = string
  default     = "10.0.0.0/8"
}

# ---- Advanced IP Defense (EDL variant) -----------------------------------------
variable "ip_defense_mode" {
  description = "\"off\" (default), \"alert\" (outbound allow+log only, nothing blocked) or \"block\" (outbound and inbound deny). Uses PANW's predefined panw-* external dynamic lists, which every folder inherits; needs a content version that carries them."
  type        = string
  default     = "off"
  validation {
    condition     = contains(["off", "alert", "block"], var.ip_defense_mode)
    error_message = "ip_defense_mode must be off, alert or block."
  }
}

variable "ip_defense_outbound_edls" {
  description = "Destination lists matched on traffic LEAVING the protected zones (command-and-control, malware, bulletproof hosting, high risk)."
  type        = list(string)
  default = [
    "panw-aipd-c2-infra-ip-list",
    "panw-aipd-in-malware-ip-list",
    "panw-bulletproof-ip-list",
    "panw-highrisk-ip-list",
  ]
}

variable "ip_defense_inbound_edls" {
  description = "Source lists denied on traffic ARRIVING from the internet in block mode (scanners, exploit services, Tor exits, bulletproof hosting, high risk)."
  type        = list(string)
  default = [
    "panw-aipd-scanning-ip-list",
    "panw-aipd-vuln-svcs-ip-list",
    "panw-torexit-ip-list",
    "panw-bulletproof-ip-list",
    "panw-highrisk-ip-list",
  ]
}
