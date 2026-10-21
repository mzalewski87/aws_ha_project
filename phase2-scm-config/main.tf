###############################################################################
# Phase 2 (path B) — Strata Cloud Manager configuration for the AWS HA pair.
#
# SCM equivalent of phase2-panorama-config/ + modules/panorama_config:
#   Panorama template stack + device group  ->  one SCM folder
#   template variables + per-device override ->  scm_variable (folder default +
#                                                device override — NATIVE, so the
#                                                raw-XML override hack of path A,
#                                                scripts/set-untrust-overrides.sh,
#                                                is not needed here)
#
# What the `scm` provider (v1.0.x) CANNOT express, and how path B covers it
# (all verified against the provider schema + pan.dev OpenAPI, 2026-10):
#   * HA + the HA2 interface    -> scripts/scm-ha.sh (REST /ha-configurations)
#   * GP portal + gateway (and their tunnel node, client IP pool, DNS)
#                               -> device-local XML API on EACH unit (SCM has no NGFW
#                                  portal/gateway object) — scripts/scm-gp-local.sh
# Rule ORDER: every rule is its own resource and Terraform creates them in
# parallel, so the allow rules are chained with depends_on and deny-all lives in
# the `post` rulebase (always evaluated last regardless of creation order).
###############################################################################

locals {
  folder = scm_folder.fw.name
}

resource "scm_folder" "fw" {
  name        = var.folder_name
  parent      = var.parent_folder
  description = "AWS VM-Series Active/Passive HA pair (path B, managed from SCM)"
}

# ---- Variables: folder default + per-device override -------------------------
# The default is a placeholder (fw1a's address); each firewall overrides it with
# its own value, exactly like Panorama template variables overridden by serial.
locals {
  folder_vars = {
    "$trust_ip"         = { type = "ip-netmask", value = var.trust_ip_default }
    "$untrust_ip"       = { type = "ip-netmask", value = var.untrust_ip_default }
    "$untrust_floating" = { type = "ip-netmask", value = var.untrust_floating_cidr }
    "$trust_gw"         = { type = "ip-netmask", value = var.trust_gateway_ip }
    "$untrust_gw"       = { type = "ip-netmask", value = var.untrust_gateway_ip }
  }
}

resource "scm_variable" "folder" {
  for_each = local.folder_vars

  name   = each.key
  type   = each.value.type
  value  = each.value.value
  folder = local.folder
}

resource "scm_variable" "device_trust_ip" {
  for_each = var.fw_devices

  name   = "$trust_ip"
  type   = "ip-netmask"
  value  = each.value.trust_ip
  device = each.key
  # The firewall must already live in the folder (scripts/scm-onboard-fw.sh).
  depends_on = [scm_variable.folder]
}

# Region-specific overrides (only for devices that set them, i.e. a pair outside Region A).
locals {
  device_region_vars = merge([
    for serial, d in var.fw_devices : {
      for name, value in {
        "$untrust_floating" = d.untrust_floating
        "$trust_gw"         = d.trust_gw
        "$untrust_gw"       = d.untrust_gw
      } : "${serial}|${name}" => { serial = serial, name = name, value = value } if value != ""
    }
  ]...)
}

resource "scm_variable" "device_region" {
  for_each = local.device_region_vars

  name       = each.value.name
  type       = "ip-netmask"
  value      = each.value.value
  device     = each.value.serial
  depends_on = [scm_variable.folder]
}

resource "scm_variable" "device_untrust_ip" {
  for_each = var.fw_devices

  name       = "$untrust_ip"
  type       = "ip-netmask"
  value      = each.value.untrust_ip
  device     = each.key
  depends_on = [scm_variable.folder]
}

# ---- Interfaces ---------------------------------------------------------------
resource "scm_interface_management_profile" "mgmt" {
  name         = "allow-mgmt-healthcheck"
  folder       = local.folder
  https        = true
  ssh          = true
  ping         = true
  permitted_ip = [for c in var.mgmt_permitted_cidrs : { name = c }]
}

# ethernet1/1 (HA2, ha mode) is NOT here: the provider has no `ha` interface
# mode. It is created by scripts/scm-ha.sh, and device_index=1 -> ethernet1/1 is
# a hard AWS requirement (see CLAUDE.md), so the ENI order in modules/firewall
# is unchanged.

# SCM models folder-level interfaces as `$variable` names with the physical port in
# `default_value` (a raw "ethernet1/3" is rejected: INVALID_STRING_REGEX). Zones,
# NAT and the virtual router reference the `$` name; a device can override it.
resource "scm_ethernet_interface" "untrust" {
  name          = "$untrust_if"
  default_value = "ethernet1/3"
  folder        = local.folder
  comment       = "untrust (public / GP + app ingress)"
  layer3 = {
    interface_management_profile = scm_interface_management_profile.mgmt.name
    ip                           = [{ name = "$untrust_ip" }]
  }
  depends_on = [scm_variable.folder]
}

resource "scm_ethernet_interface" "trust" {
  name          = "$trust_if"
  default_value = "ethernet1/2"
  folder        = local.folder
  comment       = "trust (spoke-facing / TGW)"
  layer3 = {
    ip = [{ name = "$trust_ip" }]
  }
  depends_on = [scm_variable.folder]
}

# GP portal/gateway bind to the floating /32 on a loopback (a /32 because two
# /24s on one interface is an "overlapping subnet" error in PAN-OS).
# SCM's API requires loopback names to be `$variable`-style (pattern ^\$...); the
# physical name is pinned via default_value so the device-local GP portal/gateway
# bind (a later, device-local step) can use the literal "loopback.1" like path A.
resource "scm_loopback_interface" "gp" {
  name          = "$gp_loopback"
  default_value = "loopback.1"
  folder        = local.folder
  comment       = "GP portal/gateway + SNAT floating IP"
  ip            = [{ name = "$untrust_floating" }]
  depends_on    = [scm_variable.folder]
}

resource "scm_tunnel_interface" "gp" {
  name          = "$gp_tunnel"
  default_value = "tunnel.1"
  folder        = local.folder
  comment       = "GlobalProtect tunnel"
}

# ---- Routing: Advanced Routing Engine (logical router) ------------------------
# Path B deliberately uses ARE, not the legacy virtual router of path A. The
# firewalls are bootstrapped with advance-routing:enable (init-cfg, scm mode), and
# SCM's own bootstrap push rejects a config whose interfaces are not in a logical
# router ("Interface ethernet1/2 has no logical-router configured") — which is what
# a legacy VR created through REST produced on the first live attempt.
# Next hops are the folder variables, so the one router serves both firewalls.
resource "scm_logical_router" "aws" {
  name   = "lr-aws"
  folder = local.folder

  vrf = [{
    name = "default"
    interface = [
      scm_ethernet_interface.untrust.name,
      scm_ethernet_interface.trust.name,
      scm_tunnel_interface.gp.name,
      scm_loopback_interface.gp.name,
    ]
    routing_table = {
      ip = {
        static_route = [
          {
            name        = "default-to-igw"
            destination = "0.0.0.0/0"
            interface   = scm_ethernet_interface.untrust.name
            nexthop     = { ip_address = scm_variable.folder["$untrust_gw"].name }
          },
          {
            name        = "internal-to-tgw"
            destination = var.internal_supernet
            interface   = scm_ethernet_interface.trust.name
            nexthop     = { ip_address = scm_variable.folder["$trust_gw"].name }
          },
        ]
      }
    }
  }]
}

# ---- Zones --------------------------------------------------------------------
resource "scm_zone" "untrust" {
  name   = "untrust"
  folder = local.folder
  network = {
    layer3 = [scm_ethernet_interface.untrust.name, scm_loopback_interface.gp.name]
  }
}

resource "scm_zone" "trust" {
  name   = "trust"
  folder = local.folder
  network = {
    layer3 = [scm_ethernet_interface.trust.name]
  }
}

resource "scm_zone" "vpn" {
  name   = "vpn"
  folder = local.folder
  # PAN-OS warns "Zone 'vpn' does not have 'enable-user-identification' turned on for
  # globalprotect gateway ..." without it; needed for user-based policy on VPN traffic.
  enable_user_identification = true
  network = {
    layer3 = [scm_tunnel_interface.gp.name]
  }
}

# ---- NAT ----------------------------------------------------------------------
# Same intent as path A: spokes/GP users SNAT out via the loopback floating IP
# (the EIP-bearing address); inbound app DNAT targets the floating VIP.
# Rules and NAT name their zones as plain strings, which Terraform cannot see. Without an
# explicit dependency, `destroy` deletes zones in parallel with the rules and SCM answers
# 409 "Node cannot be deleted because of references" (seen live). The first rule of each
# chain depends on the zones; the later rules inherit it through their own chain.
resource "scm_nat_rule" "outbound_snat" {
  depends_on = [scm_zone.untrust, scm_zone.trust, scm_zone.vpn]

  name        = "outbound-snat"
  folder      = local.folder
  position    = "pre"
  from        = ["trust", "vpn"]
  to          = ["untrust"]
  source      = ["any"]
  destination = ["any"]
  service     = "any"
  nat_type    = "ipv4"
  source_translation = {
    dynamic_ip_and_port = {
      interface_address = { interface = scm_loopback_interface.gp.name }
    }
  }
}

resource "scm_nat_rule" "gp_internal_snat" {
  name        = "gp-internal-snat"
  folder      = local.folder
  position    = "pre"
  from        = ["vpn"]
  to          = ["trust"]
  source      = ["any"]
  destination = ["any"]
  service     = "any"
  nat_type    = "ipv4"
  source_translation = {
    dynamic_ip_and_port = {
      interface_address = { interface = scm_ethernet_interface.trust.name }
    }
  }
  depends_on = [scm_nat_rule.outbound_snat]
}

resource "scm_nat_rule" "inbound_app_dnat" {
  name        = "inbound-app-dnat"
  folder      = local.folder
  position    = "pre"
  from        = ["untrust"]
  to          = ["untrust"]
  source      = ["any"]
  destination = ["${var.app_dnat_public_ip}/32"]
  service     = "service-http"
  nat_type    = "ipv4"
  destination_translation = {
    translated_address = var.app_private_ip
  }
  source_translation = {
    dynamic_ip_and_port = {
      interface_address = { interface = scm_ethernet_interface.trust.name }
    }
  }
  depends_on = [scm_nat_rule.gp_internal_snat]
}

# ---- Security policy (ordered by depends_on; deny-all in `post`) --------------
# PAN-OS matches security policy on PRE-NAT addresses, so inbound-app uses the
# floating VIP, not the Apache IP (see path A / CLAUDE.md).
# ---- Advanced IP Defense, EDL variant (optional, var.ip_defense_mode) ----------
# PANW publishes the IP-reputation categories as predefined external dynamic lists
# (panw-aipd-*, panw-torexit, ...) that every folder inherits — nothing to create in the tenant.
# These rules sit at the TOP of the pre-rulebase so a listed address is handled before any allow.
#   off   - no rules (default)
#   alert - outbound only, `allow` + log: nothing is blocked and no access is widened (those
#           destinations were already reachable through spokes-outbound); the rule name appears
#           in the traffic log, which is how a hit is seen. No inbound rule in this mode, because
#           an inbound "allow + log" would OPEN access that deny-all currently refuses.
#   block - outbound `deny` + inbound `deny` for the listed sources, logged.
# This is the older list-based delivery. The newer profile-based one (cloud lookup, attached to
# a ZONE, PAN-OS 12.2.3+) has no object in the SCM API or provider, so it is not used here.
locals {
  ipdef_on  = var.ip_defense_mode != "off"
  ipdef_out = var.ip_defense_mode == "block" ? "deny" : "allow"
}

resource "scm_security_rule" "ipdef_outbound" {
  count      = local.ipdef_on ? 1 : 0
  depends_on = [scm_zone.untrust, scm_zone.trust, scm_zone.vpn]

  name     = "ipdef-outbound-${var.ip_defense_mode}"
  folder   = local.folder
  position = "pre"
  # Without this a new rule is appended at the BOTTOM of the rulebase (seen live: position 10,
  # behind spokes-outbound, so it could never match and an alert would log nothing).
  relative_position = "top"
  from              = ["trust", "vpn"]
  to                = ["untrust"]
  source            = ["any"]
  destination       = var.ip_defense_outbound_edls
  application       = ["any"]
  service           = ["any"]
  action            = local.ipdef_out
  log_end           = true
}

resource "scm_security_rule" "ipdef_inbound" {
  count      = var.ip_defense_mode == "block" ? 1 : 0
  depends_on = [scm_security_rule.ipdef_outbound]

  name              = "ipdef-inbound-block"
  folder            = local.folder
  position          = "pre"
  relative_position = "top"
  from              = ["untrust"]
  to                = ["untrust", "trust"]
  source            = var.ip_defense_inbound_edls
  destination       = ["any"]
  application       = ["any"]
  service           = ["any"]
  action            = "deny"
  log_end           = true
}

resource "scm_security_rule" "guacamole_rdp" {
  depends_on = [scm_zone.untrust, scm_zone.trust, scm_zone.vpn, scm_security_rule.ipdef_inbound]

  count = length(var.guac_rdp_source_cidrs) > 0 && var.dc_private_ip != "" ? 1 : 0

  name        = "guacamole-rdp-to-dc"
  folder      = local.folder
  position    = "pre"
  from        = ["trust"]
  to          = ["trust"]
  source      = var.guac_rdp_source_cidrs
  destination = ["${var.dc_private_ip}/32"]
  application = ["ms-rdp"]
  service     = ["application-default"]
  action      = "allow"
  log_end     = true
}

resource "scm_security_rule" "panel_ldap" {
  depends_on = [scm_zone.trust, scm_security_rule.guacamole_rdp]

  count = length(var.panel_source_cidrs) > 0 && var.dc_private_ip != "" ? 1 : 0

  name        = "panel-ldap-to-dc"
  folder      = local.folder
  position    = "pre"
  from        = ["trust"]
  to          = ["trust"]
  source      = var.panel_source_cidrs
  destination = ["${var.dc_private_ip}/32"]
  application = ["ldap"]
  service     = ["application-default"]
  action      = "allow"
  log_end     = true
}

# Guacamole AD sign-in (root guac_ldap_enabled): the host binds to the DC over LDAP, through the
# firewalls like its RDP. Separate from panel-ldap-to-dc so each source can be removed on its own.
resource "scm_security_rule" "guacamole_ldap" {
  depends_on = [scm_zone.trust, scm_security_rule.panel_ldap]

  count = length(var.guac_ldap_source_cidrs) > 0 && var.dc_private_ip != "" ? 1 : 0

  name        = "guacamole-ldap-to-dc"
  folder      = local.folder
  position    = "pre"
  from        = ["trust"]
  to          = ["trust"]
  source      = var.guac_ldap_source_cidrs
  destination = ["${var.dc_private_ip}/32"]
  application = ["ldap"]
  service     = ["application-default"]
  action      = "allow"
  log_end     = true
}

resource "scm_security_rule" "dc_replication" {
  depends_on = [scm_zone.trust, scm_security_rule.panel_ldap]

  count = length(var.dc_replica_ips) >= 2 ? 1 : 0

  name        = "dc-replication"
  folder      = local.folder
  position    = "pre"
  from        = ["trust"]
  to          = ["trust"]
  source      = [for ip in var.dc_replica_ips : "${ip}/32"]
  destination = [for ip in var.dc_replica_ips : "${ip}/32"]
  application = ["any"]
  service     = ["any"]
  action      = "allow"
  log_end     = true
}

resource "scm_security_rule" "gp_users_to_internal" {
  name        = "gp-users-to-internal"
  folder      = local.folder
  position    = "pre"
  from        = ["vpn"]
  to          = ["trust", "untrust"]
  source      = ["any"]
  destination = ["any"]
  application = ["any"]
  service     = ["application-default"]
  action      = "allow"
  log_end     = true
  depends_on  = [scm_security_rule.panel_ldap, scm_security_rule.dc_replication]
}

resource "scm_security_rule" "spokes_outbound" {
  name        = "spokes-outbound"
  folder      = local.folder
  position    = "pre"
  from        = ["trust"]
  to          = ["untrust"]
  source      = ["any"]
  destination = ["any"]
  application = ["any"]
  service     = ["application-default"]
  action      = "allow"
  log_end     = true
  depends_on  = [scm_security_rule.gp_users_to_internal]
}

resource "scm_security_rule" "inbound_app" {
  name        = "inbound-app"
  folder      = local.folder
  position    = "pre"
  from        = ["untrust"]
  to          = ["trust"]
  source      = ["any"]
  destination = ["${var.app_dnat_public_ip}/32"]
  application = ["web-browsing", "ssl"]
  service     = ["application-default"]
  action      = "allow"
  log_end     = true
  depends_on  = [scm_security_rule.spokes_outbound]
}

# Inbound GlobalProtect is intrazone untrust->untrust self-traffic and WOULD be
# eaten by deny-all without this explicit allow.
resource "scm_security_rule" "gp_portal_gateway_inbound" {
  name        = "gp-portal-gateway-inbound"
  folder      = local.folder
  position    = "pre"
  from        = ["untrust"]
  to          = ["untrust"]
  source      = ["any"]
  destination = [for ip in var.gp_local_ips : "${ip}/32"]
  application = ["any"]
  service     = ["service-https", "service-http", scm_service.gp_ipsec.name]
  action      = "allow"
  log_end     = true
  depends_on  = [scm_security_rule.inbound_app]
}

resource "scm_security_rule" "deny_all" {
  depends_on = [scm_zone.untrust, scm_zone.trust, scm_zone.vpn]

  name        = "deny-all"
  folder      = local.folder
  position    = "post"
  from        = ["any"]
  to          = ["any"]
  source      = ["any"]
  destination = ["any"]
  application = ["any"]
  service     = ["any"]
  action      = "deny"
  log_end     = true
}

# PAN-OS has no built-in service for UDP 4501 (GP IPSec data port); without this
# the GP rule is TCP-only and tunnels silently fall back to SSL.
resource "scm_service" "gp_ipsec" {
  name        = "gp-ipsec-udp4501"
  folder      = local.folder
  description = "GlobalProtect IPSec data port"
  protocol = {
    udp = { port = "4501" }
  }
}
