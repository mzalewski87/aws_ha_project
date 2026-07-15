###############################################################################
# Phase 2a — variables. Values marked "(from Phase 1 output)" come from the root
# workspace: `cd .. && terraform output`.
###############################################################################

# --- panos provider connection (SSM tunnel) ---------------------------------
variable "panorama_hostname" {
  description = "Panorama host as seen by the panos provider — localhost via the SSM tunnel."
  type        = string
  default     = "127.0.0.1"
}

variable "panorama_port" {
  description = "Local port the SSM tunnel forwards to Panorama:443."
  type        = number
  default     = 44300
}

variable "panorama_username" {
  description = "Panorama admin username."
  type        = string
  default     = "admin"
}

variable "panorama_password" {
  description = "Panorama admin password."
  type        = string
  sensitive   = true
}

variable "panorama_serial_number" {
  description = "Panorama serial number (from CSP; register the Panorama auth code). Set on the device so it can fetch its management license. Empty = skip activation."
  type        = string
  default     = ""
}

variable "panorama_device_otp" {
  description = "One-Time Password from CSP (Assets -> Device Certificates -> Generate OTP) for the Panorama serial. Single-use, 60-min TTL. Needed so Panorama gets a device certificate — a FW that has a device cert only connects to a Panorama that also has one. Empty = skip the cert fetch."
  type        = string
  default     = ""
  sensitive   = true
}

# --- vm-auth-key handoff -----------------------------------------------------
variable "vm_auth_key_lifetime_hours" {
  description = "Lifetime (hours) for the generated device-registration vm-auth-key."
  type        = number
  default     = 168
}

variable "vm_auth_key_output_path" {
  description = "Where to write the generated key for Phase 1b to auto-load."
  type        = string
  default     = "../panorama_vm_auth_key.auto.tfvars"
}

# --- Panorama object names (must match FW init-cfg tplname=/dgname=) ---------
variable "template_name" {
  type    = string
  default = "AWS-Transit-Template"
}
variable "template_stack_name" {
  type    = string
  default = "AWS-Transit-Stack"
}
variable "device_group_name" {
  type    = string
  default = "AWS-Transit-DG"
}

# --- Dataplane / routing (from Phase 1 output / CIDR plan) ------------------
variable "untrust_gateway_ip" {
  description = "AWS untrust subnet gateway (.1). Region A default: 10.10.10.1."
  type        = string
  default     = "10.10.10.1"
}
variable "trust_gateway_ip" {
  description = "AWS trust subnet gateway (.1). Region A default: 10.10.20.1."
  type        = string
  default     = "10.10.20.1"
}
variable "mgmt_permitted_cidrs" {
  description = "CIDRs permitted on the interface mgmt profile (NLB health checks come from the VPC CIDR)."
  type        = list(string)
  default     = ["10.10.0.0/16", "10.11.0.0/16"]
}

# --- App DNAT (from Phase 1 output) -----------------------------------------
variable "app_dnat_public_ip" {
  description = "FW untrust floating IP the app is published on (root output fw_public_eip maps here; use the floating private IP for the DNAT match). Default 10.10.10.100."
  type        = string
  default     = "10.10.10.100"
}
variable "app_private_ip" {
  description = "Spoke1 Apache private IP (DNAT target). Default 10.12.0.10."
  type        = string
  default     = "10.12.0.10"
}

# --- Untrust static addressing (required for GlobalProtect binding) ----------
variable "fw_untrust_static_ips" {
  description = "Per-firewall untrust PRIMARY IP in CIDR, keyed by fw name (fw1a/fw2a Region A, fw1b/fw2b Region B). Replaces DHCP so GP local_address can bind; matches root fw_host_offsets."
  type        = map(string)
  default = {
    fw1a = "10.10.10.11/24", fw2a = "10.10.10.12/24"
    fw1b = "10.20.10.11/24", fw2b = "10.20.10.12/24"
  }
}
variable "fw_untrust_floating_ips" {
  description = "Per-firewall untrust FLOATING IP (/32) carrying the public EIP; GP portal/gateway bind here. Same within a region, different across regions. MUST be /32 (a /24 overlaps the primary's subnet)."
  type        = map(string)
  default = {
    fw1a = "10.10.10.100/32", fw2a = "10.10.10.100/32"
    fw1b = "10.20.10.100/32", fw2b = "10.20.10.100/32"
  }
}
variable "untrust_floating_cidr" {
  description = "Template-level DEFAULT for the floating-IP variable (Region A value). Per-device values come from fw_untrust_floating_ips. MUST be /32."
  type        = string
  default     = "10.10.10.100/32"
}
variable "gp_local_ips" {
  description = "Per-region floating IPs (bare) the GP portal/gateway bind to — destination of the inbound-GP allow rule. Region A only by default; add Region B (10.20.10.100) for multi-region."
  type        = list(string)
  default     = ["10.10.10.100"]
}
variable "fw_serials" {
  description = "PAN-OS serials keyed by fw name (fw1a/fw2a/fw1b/fw2b), for per-device template-variable overrides of untrust primary + floating. Empty until firewalls register; fill in for Phase GP (from `show devices connected`)."
  type        = map(string)
  default     = {}
}

# --- GlobalProtect (Phase GP) -----------------------------------------------
variable "enable_globalprotect" {
  description = "Create the GP portal/gateway (requires a server cert)."
  type        = bool
  default     = false
}
variable "gp_gateway_name" {
  description = "GlobalProtect gateway name (must match the panorama_config module). Used to name the network-side tunnel node too."
  type        = string
  default     = "gp-gateway-eu-central"
}
variable "gp_tunnel_interface" {
  description = "Tunnel interface the GP gateway terminates client tunnels on (bound in the network-side tunnel node)."
  type        = string
  default     = "tunnel.1"
}
variable "gp_local_interface" {
  description = "Dataplane interface the GP gateway/tunnel binds its local-address to (the untrust interface)."
  type        = string
  default     = "loopback.1"
}
variable "gp_client_version" {
  description = "GlobalProtect app package version to download + activate on each firewall so the portal can serve the installer, or \"latest\" to auto-resolve the newest available. Firewalls need PANW update-server egress."
  type        = string
  default     = "latest"
}

variable "gp_ip_pool" {
  type    = list(string)
  default = ["10.10.200.0/24"]
}
variable "gp_split_tunnel_routes" {
  type    = list(string)
  default = ["10.0.0.0/8"]
}
variable "gp_dns_servers" {
  type    = list(string)
  default = ["10.11.0.2"]
}
variable "gp_external_gateways" {
  description = "Portal external gateway list (all regions). Region B appended in Phase R2."
  type = list(object({
    name     = string
    address  = string
    priority = string
  }))
  default = []
}
variable "gp_server_cert_pem" {
  type      = string
  default   = ""
  sensitive = true
}
variable "gp_server_key_pem" {
  type      = string
  default   = ""
  sensitive = true
}
variable "gp_local_users" {
  description = "Baseline GP local users (username => password). Replace with SAML/LDAP in production."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "gp_auth_method" {
  description = "GP authentication backend: \"local\" (gp_local_users, default) or \"ldap\" (against the spoke2 AD DC — promote it first with root dc_promote_to_dc)."
  type        = string
  default     = "local"
}

variable "gp_ldap_server_ip" {
  description = "Primary AD DC private IP (root output dc_private_ip, Region A) — required when gp_auth_method = \"ldap\"."
  type        = string
  default     = ""
}

variable "gp_ldap_extra_server_ips" {
  description = "Additional AD DC IPs (e.g. the Region B DC, root output dc_private_ip_b) appended after the primary for region-outage LDAP failover. Empty for single-DC."
  type        = list(string)
  default     = []
}

variable "gp_ldap_base_dn" {
  description = "LDAP base DN, e.g. \"DC=panw,DC=labs\" for domain panw.labs (root dc_domain_name)."
  type        = string
  default     = ""
}

variable "gp_vpn_group" {
  description = "AD group whose members may connect via GlobalProtect (LDAP auth). Enforced via group-mapping + auth allow-list; must match the root gp_vpn_group (the group auto-created on the DC)."
  type        = string
  default     = "vpnusers"
}

variable "gp_ldap_bind_dn" {
  description = "LDAP bind DN/UPN, e.g. \"admin@panw.labs\" — the AD test user from root dc_ad_test_user_name works for this."
  type        = string
  default     = ""
}

variable "gp_ldap_bind_password" {
  description = "Password for gp_ldap_bind_dn (root dc_ad_test_user_password if using the AD test user)."
  type        = string
  default     = ""
  sensitive   = true
}

# --- EKS egress EDL (optional/eks-deploy) -----------------------------------
variable "enable_edl" {
  description = "Create the EKS-egress EDLs + egress-allow rule (pair with optional/eks-deploy)."
  type        = bool
  default     = false
}
variable "edl_server_ip" {
  description = "Private IP of the EDL server (optional/eks-deploy output)."
  type        = string
  default     = ""
}

# --- Log collector -----------------------------------------------------------
variable "enable_log_collector" {
  description = "Run the Panorama log-collector setup (disk-pair + Collector Group bind + commit-all)."
  type        = bool
  default     = true
}
variable "log_collector_add_disk" {
  description = "Add the EBS log volume to the logging disk-pair (best-effort; confirm disk id on the box)."
  type        = bool
  default     = true
}
variable "log_collector_restart" {
  description = "Restart Panorama after disk add to (re)initialize the log DB. DISRUPTIVE — off by default."
  type        = bool
  default     = false
}

variable "fw_untrust_gateways" {
  description = "Per-firewall untrust default-gateway (subnet .1) in CIDR, keyed by fw name. Per-region default-route next hop."
  type        = map(string)
  default = {
    fw1a = "10.10.10.1/32", fw2a = "10.10.10.1/32"
    fw1b = "10.20.10.1/32", fw2b = "10.20.10.1/32"
  }
}
variable "fw_trust_gateways" {
  description = "Per-firewall trust gateway (subnet .1) in CIDR, keyed by fw name. Per-region internal-route next hop toward the TGW."
  type        = map(string)
  default = {
    fw1a = "10.10.20.1/32", fw2a = "10.10.20.1/32"
    fw1b = "10.20.20.1/32", fw2b = "10.20.20.1/32"
  }
}
