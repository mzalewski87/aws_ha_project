###############################################################################
# modules/custom_domain — variables
#
# Optional custom domain for the GlobalProtect portal + gateways. Two independent
# concerns, both feature-flagged:
#   1. DNS  — a Route53 hosted zone for a DELEGATED subdomain (e.g.
#      lab.example.com) plus A records: portal -> Global Accelerator anycast IPs,
#      one gateway record per region -> that region's firewall EIP.
#   2. CERT — either self-signed (default, handled outside this module by feeding
#      PAN-OS a self-signed PEM) or a Let's Encrypt wildcard obtained via DNS-01
#      against the very Route53 zone created here (no HTTP reachability needed).
#
# Nothing here is hardcoded to a real domain — the deployer supplies every name.
###############################################################################

variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
}

variable "enable" {
  description = "Master switch. false = create nothing (self-signed IP-only GP, the default)."
  type        = bool
  default     = false
}

# --- DNS ---------------------------------------------------------------------
variable "subdomain_zone" {
  description = "The DELEGATED subdomain to host in Route53, e.g. \"lab.example.com\". You create it here, then delegate it once from the parent domain by pointing NS records at this zone's name servers (module output name_servers)."
  type        = string
  default     = ""
}

variable "portal_hostname" {
  description = "Left label for the portal record within subdomain_zone, e.g. \"gp\" -> gp.lab.example.com. This is the name GlobalProtect users type."
  type        = string
  default     = "gp"
}

variable "portal_target_ips" {
  description = "IPs the portal record resolves to — the Global Accelerator anycast IPs (multi-region) or a single portal EIP. A records."
  type        = list(string)
  default     = []
}

variable "gateway_records" {
  description = "Per-region gateway records: label (left of subdomain_zone, e.g. \"gw-a\") => firewall EIP. GlobalProtect clients dial these by FQDN; the portal's external-gateway list should use the same FQDNs."
  type        = map(string)
  default     = {}
}

variable "record_ttl" {
  description = "TTL (seconds) for the A records."
  type        = number
  default     = 60
}

# --- CERT (Let's Encrypt DNS-01) --------------------------------------------
variable "cert_mode" {
  description = "\"self_signed\" (default; this module issues no cert) or \"letsencrypt\" (wildcard cert for *.subdomain_zone via DNS-01 against the Route53 zone here)."
  type        = string
  default     = "self_signed"
  validation {
    condition     = contains(["self_signed", "letsencrypt"], var.cert_mode)
    error_message = "cert_mode must be \"self_signed\" or \"letsencrypt\"."
  }
}

variable "letsencrypt_email" {
  description = "Registration/recovery email for the Let's Encrypt account (required when cert_mode = letsencrypt)."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
