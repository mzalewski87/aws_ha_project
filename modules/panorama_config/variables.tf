###############################################################################
# modules/panorama_config — variables (panos v2)
#
# Declarative PAN-OS config pushed from Panorama: template + template stack +
# device group, dataplane interfaces (DHCP client, AWS-style), a SINGLE virtual
# router (TGW appliance mode gives flow symmetry — no dual-VR trick), zones,
# static routes, and baseline NAT + security policy. GlobalProtect objects live
# in gp.tf and are gated by var.enable_globalprotect.
###############################################################################

variable "template_name" {
  description = "Panorama template name."
  type        = string
  default     = "AWS-Transit-Template"
}

variable "template_stack_name" {
  description = "Panorama template stack name (must match FW init-cfg tplname=)."
  type        = string
  default     = "AWS-Transit-Stack"
}

variable "device_group_name" {
  description = "Panorama device group name (must match FW init-cfg dgname=)."
  type        = string
  default     = "AWS-Transit-DG"
}

variable "vsys" {
  description = "Target vsys."
  type        = string
  default     = "vsys1"
}

# --- Dataplane / routing -----------------------------------------------------

variable "untrust_gateway_ip" {
  description = "AWS untrust subnet gateway (.1) — default-route next hop."
  type        = string
}

variable "trust_gateway_ip" {
  description = "AWS trust subnet gateway (.1) — internal-return next hop toward the TGW."
  type        = string
}

variable "internal_supernet" {
  description = "Internal supernet reachable via the trust interface / TGW."
  type        = string
  default     = "10.0.0.0/8"
}

variable "mgmt_permitted_cidrs" {
  description = "CIDRs permitted on the interface management profile (health checks / mgmt). AWS NLB health checks originate from the VPC CIDR."
  type        = list(string)
}

variable "virtual_router_name" {
  description = "Virtual router name."
  type        = string
  default     = "vr-transit"
}

# --- Untrust static addressing (required for GlobalProtect binding) ----------
# The untrust interface is static (not DHCP) so GP's local_address can bind an
# IP declared on the interface. The per-device primary is a template variable
# overridden by serial; the floating IP is shared. See main.tf / gp.tf.

variable "untrust_ip_variable_name" {
  description = "Panorama template-variable name for the per-device untrust primary IP (referenced by the untrust interface)."
  type        = string
  default     = "$fw_untrust_ip"
}

variable "untrust_floating_variable_name" {
  description = "Panorama template-variable name for the per-REGION untrust floating IP (referenced by the untrust interface AND GP local_address). Overridden per-device by serial so each region's firewalls bind their own floating IP."
  type        = string
  default     = "$fw_untrust_floating"
}

variable "untrust_gw_variable_name" {
  description = "Template-variable name for the per-region untrust default-gateway (subnet .1) used as the default-route next hop."
  type        = string
  default     = "$fw_untrust_gw"
}

variable "trust_gw_variable_name" {
  description = "Template-variable name for the per-region trust gateway (subnet .1) used as the internal-route next hop toward the TGW."
  type        = string
  default     = "$fw_trust_gw"
}

variable "fw_untrust_static_ips" {
  description = "Per-firewall untrust primary IP in CIDR, keyed by fw name (fw1a/fw2a/fw1b/fw2b). Only [\"fw1a\"] is used here (template default); per-device values are set in phase2. AWS assigns these deterministically (fw_host_offsets)."
  type        = map(string)
  default     = { fw1a = "10.10.10.11/24", fw2a = "10.10.10.12/24" }
}

variable "untrust_floating_cidr" {
  description = "TEMPLATE-LEVEL DEFAULT for the floating-IP variable (Region A value). Per-region values are overridden per-device in phase2. MUST be /32: PAN-OS rejects two addresses in the same subnet on one interface (\"overlapping subnet\"), so the floating is a /32 alongside the /24 primary."
  type        = string
  default     = "10.10.10.100/32"
}

variable "gp_local_ips" {
  description = "Per-region floating IPs (bare, no mask) the GP portal/gateway bind to — used as the destination of the inbound-GP allow rule. One per region (Region A 10.10.10.100; add Region B 10.20.10.100 for multi-region)."
  type        = list(string)
  default     = ["10.10.10.100"]
}

# NOTE: per-device untrust overrides (by serial) are handled in
# phase2-panorama-config via the raw XML API, not by this module — see the note
# on panos_template_variable.untrust_ip_default in main.tf. So no fw_serials var
# here; the module only needs the template-level default + the interface.

# --- App DNAT ----------------------------------------------------------------

variable "app_dnat_public_ip" {
  description = "Untrust-side IP the app is published on (the FW untrust floating IP)."
  type        = string
}

variable "app_private_ip" {
  description = "Spoke1 Apache private IP (DNAT translated address)."
  type        = string
}

# --- GlobalProtect (see gp.tf) ----------------------------------------------

variable "enable_globalprotect" {
  description = "Create the GlobalProtect portal/gateway objects. Requires a server cert (var.gp_server_cert_*)."
  type        = bool
  default     = false
}

variable "gp_gateway_name" {
  description = "GlobalProtect gateway name."
  type        = string
  default     = "gp-gateway-eu-central"
}

# --- Panorama API (for the in-module GP network-side tunnel node) ------------
# The tunnel-mode GP gateway references a network-side tunnel node
# (network/tunnel/global-protect-gateway) the panos provider can't model; it is
# created by scripts/set-gp-tunnel-node.sh via a null_resource INSIDE this module
# so it runs BEFORE the gateway (a fresh single apply otherwise fails with
# "remote-user-tunnel 'tunnel.1' is not a valid reference"). That needs the same
# Panorama API connection the panos provider uses.
variable "panorama_hostname" {
  type    = string
  default = "127.0.0.1"
}
variable "panorama_port" {
  type    = number
  default = 44300
}
variable "panorama_username" {
  type    = string
  default = "admin"
}
variable "panorama_password" {
  type      = string
  default   = ""
  sensitive = true
}
variable "gp_tunnel_interface" {
  description = "Tunnel interface the GP gateway terminates client tunnels on."
  type        = string
  default     = "tunnel.1"
}
variable "gp_local_interface" {
  description = "Dataplane interface the GP gateway/tunnel binds its local-address to (untrust)."
  type        = string
  default     = "loopback.1"
}

variable "gp_portal_name" {
  description = "GlobalProtect portal name."
  type        = string
  default     = "gp-portal"
}

variable "gp_ip_pool" {
  description = "GlobalProtect client IP pool(s) for Region A (non-overlapping across regions)."
  type        = list(string)
  default     = ["10.10.200.0/24"]
}

variable "gp_split_tunnel_routes" {
  description = "Access routes pushed to GP clients (split tunnel include)."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "gp_dns_servers" {
  description = "DNS servers pushed to GP clients."
  type        = list(string)
  default     = ["10.11.0.2"]
}

variable "gp_external_gateways" {
  description = <<-EOT
    External gateway list advertised by the portal (all regions + priorities).
    Each entry: { name, fqdn_or_ip, priority }. Region B is added in Phase R2.
  EOT
  type = list(object({
    name     = string
    address  = string
    priority = string
  }))
  default = []
}

variable "gp_server_cert_name" {
  description = "Name of the imported server certificate used by the portal/gateway SSL-TLS profile."
  type        = string
  default     = "gp-server-cert"
}

variable "gp_server_cert_pem" {
  description = "PEM-encoded server certificate (public CA or exported ACM cert — PAN-OS cannot consume ACM directly)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "gp_server_key_pem" {
  description = "PEM-encoded private key for the server certificate."
  type        = string
  default     = ""
  sensitive   = true
}

variable "gp_auth_profile_name" {
  description = "Authentication profile name for GP. Shared by both the local-database and LDAP variants (gp.tf) — only one is ever created, gated by gp_auth_method, so there's no collision."
  type        = string
  default     = "gp-auth"
}

variable "gp_local_users" {
  description = "Map of GP local username => password (baseline auth; replace with SAML/LDAP)."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "gp_auth_method" {
  description = "GP authentication backend: \"local\" (panos_local_user / gp_local_users, default) or \"ldap\" (against the spoke2 AD DC — promote it first, see modules/spoke2_dc)."
  type        = string
  default     = "local"
  validation {
    condition     = contains(["local", "ldap"], var.gp_auth_method)
    error_message = "gp_auth_method must be \"local\" or \"ldap\"."
  }
}

variable "gp_ldap_server_ip" {
  description = "Primary LDAP server IP (the Region A AD DC's private IP) — required when gp_auth_method = \"ldap\"."
  type        = string
  default     = ""
}

variable "gp_ldap_extra_server_ips" {
  description = "Additional LDAP server IPs (e.g. the Region B DC) appended to the LDAP profile after the primary, for region-outage failover. Empty for single-DC deployments."
  type        = list(string)
  default     = []
}

variable "gp_ldap_bind_timelimit" {
  description = "Per-server LDAP TCP connect timeout (seconds). LOW so GP auth fails over to the surviving-region DC fast during a region outage (PAN-OS default 30s is too slow — getconfig times out first). 3-5s is plenty for a healthy cross-region connect."
  type        = number
  default     = 3
}

variable "gp_ldap_search_timelimit" {
  description = "LDAP search time limit (seconds)."
  type        = number
  default     = 5
}

variable "gp_ldap_retry_interval" {
  description = "Seconds before PAN-OS retries a downed LDAP server (keeps a dead-region DC from being hammered)."
  type        = number
  default     = 60
}

variable "gp_ldap_base_dn" {
  description = "LDAP base distinguished name for searches, e.g. \"DC=panw,DC=labs\" for domain panw.labs."
  type        = string
  default     = ""
}

variable "gp_vpn_group" {
  description = "AD group whose members may connect via GlobalProtect (LDAP auth). Enforced via LDAP group-mapping + the GP auth-profile allow-list. Only takes effect for gp_auth_method=ldap with gp_ldap_base_dn set; must match the group auto-created on the DC (root gp_vpn_group)."
  type        = string
  default     = "vpnusers"
}

variable "gp_ldap_bind_dn" {
  description = "LDAP bind DN/UPN used to query the directory, e.g. \"admin@panw.labs\" (the AD test user created by scripts/create-ad-test-user.sh works for this)."
  type        = string
  default     = ""
}

variable "gp_ldap_bind_password" {
  description = "Password for gp_ldap_bind_dn."
  type        = string
  default     = ""
  sensitive   = true
}

# --- EKS egress EDL (optional/eks-deploy — see edl.tf) -----------------------

variable "enable_edl" {
  description = "Create the EKS-egress External Dynamic Lists + the egress-allow rule (used with optional/eks-deploy)."
  type        = bool
  default     = false
}

variable "edl_server_ip" {
  description = "Private IP of the EDL server (optional/eks-deploy edl_server). EDL URLs are built from this."
  type        = string
  default     = ""
}
