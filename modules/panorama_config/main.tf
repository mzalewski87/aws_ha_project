###############################################################################
# modules/panorama_config — main (panos v2)
#
# NOTE: panos v2 is a terraform-plugin-framework rewrite; every resource takes a
# `location` block selecting where the config lands (panorama template / device
# group). This is the transit baseline; GlobalProtect is in gp.tf.
#
# This config is authored against the v2 schema and `terraform validate`-clean,
# but PAN-OS policy inherently needs live iteration against Panorama — treat the
# rule/interface specifics as a starting baseline, not a turnkey ruleset.
###############################################################################

terraform {
  required_providers {
    panos = { source = "PaloAltoNetworks/panos" }
    null  = { source = "hashicorp/null" }
  }
}

locals {
  tpl_loc  = { template = { name = var.template_name } }
  tpl_vsys = { template = { name = var.template_name, vsys = var.vsys } }
  # NOT the same shape as tpl_vsys above: panos_zone/panos_ethernet_interface
  # accept `vsys` nested inside `template`, but panos_globalprotect_gateway/
  # portal reject that xpath ("Could not find schema node") and require the
  # dedicated `template_vsys` location kind (template + vsys as siblings).
  gp_tpl_vsys = { template_vsys = { template = var.template_name, vsys = var.vsys } }
  dg_loc      = { device_group = { name = var.device_group_name } }
  panorama_dg = { panorama = {} }
}

###############################################################################
# Template / template stack / device group
###############################################################################
resource "panos_template" "tpl" {
  location = local.panorama_dg
  name     = var.template_name
}

resource "panos_template_stack" "stack" {
  location  = local.panorama_dg
  name      = var.template_stack_name
  templates = [panos_template.tpl.name]
  # REQUIRED: without default_vsys, PAN-OS rejects ANY commit that assigns a
  # device to this template-stack with "Validation Error: ... is missing
  # 'settings'" (the whole commit fails, silently leaving mgt-config/device-
  # group/template-stack device assignments uncommitted). VM-Series without
  # multi-vsys licensing always has a single vsys named "vsys1".
  default_vsys = "vsys1"

  # default_vsys="vsys1" requires vsys1 to already exist in the referenced
  # template, and vsys1 is only created implicitly by the first object placed
  # under it (the zones, via local.tpl_vsys). Without this depends_on the stack
  # can be created before any zone (it only references panos_template.tpl), and
  # PAN-OS rejects it with "settings -> default-vsys is invalid" — a race that
  # fails intermittently on a clean apply. Ordering the stack after the zones
  # makes vsys1 exist first.
  depends_on = [panos_zone.untrust, panos_zone.trust, panos_zone.vpn]

  # Same as the device group below: firewall membership is set by register-fw-
  # panorama.sh, not Terraform. Without ignore_changes a later apply clears the
  # stack's devices too and the firewalls stop receiving the template.
  lifecycle {
    ignore_changes = [devices]
  }
}

resource "panos_device_group" "dg" {
  location = local.panorama_dg
  name     = var.device_group_name

  # Device (firewall serial) membership is managed by scripts/register-fw-
  # panorama.sh AFTER the firewalls register, NOT by Terraform (serials aren't
  # known at plan time). Without this, every phase2 apply rewrites the group
  # with an empty devices list and SILENTLY UN-ASSIGNS both firewalls — so the
  # device-group security policy stops being pushed and the FWs fall back to
  # intrazone/interzone-default only (GP + all custom rules vanish from the FW
  # running config after a later apply, while commit-all still reports OK).
  lifecycle {
    ignore_changes = [devices]
  }
}

###############################################################################
# Interface management profile (health-check / mgmt permitted IPs)
###############################################################################
resource "panos_interface_management_profile" "mgmt" {
  location = local.tpl_loc
  name     = "allow-mgmt-healthcheck"
  https    = true
  ssh      = true
  ping     = true

  permitted_ips = [for c in var.mgmt_permitted_cidrs : { name = c }]
}

###############################################################################
# Dataplane interfaces (AWS: DHCP client picks up the ENI IP)
###############################################################################

# AWS requires ethernet1/1 to be the HA2 link (VM-Series Deployment Guide,
# "HA Links": unconditional, not just an example). PAN-OS's own `show
# interface hardware`/`show interface all` only list interfaces that have
# SOME panos-side config touching them ("total CONFIGURED hardware
# interfaces") -- an ENI with no panos_ethernet_interface resource at all
# is invisible there even though the guest kernel and AWS both see it fine.
# This looks like a missing-hardware bug but the interface is simply
# unconfigured, not undetected — declaring it here (below) makes it visible.
resource "panos_ethernet_interface" "ha2" {
  location = local.tpl_loc
  name     = "ethernet1/1"
  comment  = "ha2 (state sync data link)"
  ha       = {}
}

# untrust is STATIC (not DHCP). GlobalProtect's local_address can only bind an
# IP that is statically declared on the interface (empirically verified on live
# Panorama: PAN-OS accepts an interface-only local_address, but the panos
# provider's schema forces exactly one of ip/floating_ip, and PAN-OS then
# rejects any ip that is not present in the interface config with "not a valid
# reference"). DHCP and static `ips` are mutually exclusive on one PAN-OS
# interface ("DHCP interface IP address must be empty"), so the whole interface
# goes static. Two addresses:
#   - the per-device primary (.11 for fw1, .12 for fw2), via a Panorama template
#     VARIABLE overridden per-device by serial (see panos_template_variable
#     below) — this is what DHCP used to supply, and what the app NLB health-
#     checks target;
#   - the shared floating IP (.100/24) that carries the public EIP and moves on
#     failover via the AWS HA plugin — GP portal/gateway bind here.
resource "panos_ethernet_interface" "untrust" {
  location = local.tpl_loc
  name     = "ethernet1/3"
  comment  = "untrust (public / GP + app ingress)"

  layer3 = {
    interface_management_profile = panos_interface_management_profile.mgmt.name
    ips = [
      { name = var.untrust_ip_variable_name }, # per-device primary (.11/.12 / .20.11/.12) via template variable
    ]
  }
}

# The floating IP (.100) that carries the public EIP is bound on a LOOPBACK, not
# on the L3 untrust interface. WHY: a tunnel-mode GP gateway's SSL server binds
# its tunnel node's local-address, which follows the interface's PRIMARY IP — so
# with the floating as an untrust secondary the gateway bound the untrust primary
# (.11, no EIP) and was unreachable, while PAN-OS also rejects the floating as
# BOTH an untrust secondary AND the tunnel local-address ("ip already in use").
# Putting the floating on a dedicated loopback (its only/primary IP) lets the
# portal, gateway, and tunnel node all bind it cleanly. The floating stays an ENI
# secondary at the AWS level (EIP + HA-plugin failover unchanged); traffic to it
# arrives on untrust and is delivered locally to the loopback (same untrust zone).
resource "panos_loopback_interface" "gp" {
  location = local.tpl_loc
  name     = "loopback.1"
  comment  = "GP portal/gateway floating-IP bind"
  ip       = [{ name = var.untrust_floating_variable_name }]
}

# Per-device untrust primary IP. The untrust interface (above) references this
# variable; its value differs per firewall (fw1 .11, fw2 .12). PAN-OS resolves
# template variables per-device, so one shared template drives two distinct IPs.
#
#   - The TEMPLATE-level definition is the default, so the template is
#     self-consistent and commits even before any firewall is registered
#     (Phase 2a runs before the firewalls exist).
#   - The per-device overrides at the TEMPLATE-STACK level (keyed by serial)
#     set each firewall's real primary. var.fw_serials is empty until the
#     firewalls are registered, so these are created in Phase GP once serials
#     are known (see docs/DEPLOYMENT.md).
resource "panos_template_variable" "untrust_ip_default" {
  location = local.tpl_loc
  name     = var.untrust_ip_variable_name
  type     = { ip_netmask = var.fw_untrust_static_ips["fw1a"] }
}

# Per-REGION floating IP (the address the EIP rides + GP binds). Same value for
# both firewalls in a region, different per region (Region A 10.10.10.100/32,
# Region B 10.20.10.100/32). Template-level default keeps the template valid;
# per-device overrides (by serial) are set in phase2 (null_resource, XML API)
# once serials are known. GP gateway/portal local_address references this var,
# so a single shared template drives correct per-region GP.
resource "panos_template_variable" "untrust_floating_default" {
  location = local.tpl_loc
  name     = var.untrust_floating_variable_name
  type     = { ip_netmask = var.untrust_floating_cidr }
}

# Per-device overrides of $fw_untrust_ip (fw1 .11, fw2 .12) are NOT managed here:
# panos_template_variable with location.template_stack.panorama_device is broken
# for more than one device (two resources collide on the shared devices/entry
# node -> "At most 1 occurrence is allowed for devices/entry"). They are set via
# the raw XML API in phase2-panorama-config (null_resource.untrust_ip_overrides
# -> scripts/set-untrust-overrides.sh), keyed by serial. The template-level
# default above keeps the template valid before serials are known.

resource "panos_ethernet_interface" "trust" {
  location = local.tpl_loc
  name     = "ethernet1/2"
  comment  = "trust (spoke-facing / TGW)"

  layer3 = {
    dhcp_client = {
      enable               = true
      create_default_route = false
    }
  }
}

resource "panos_tunnel_interface" "gp" {
  location = local.tpl_loc
  name     = "tunnel.1"
  comment  = "GlobalProtect tunnel"
}

###############################################################################
# Zones
###############################################################################
resource "panos_zone" "untrust" {
  location = local.tpl_vsys
  name     = "untrust"
  network  = { layer3 = [panos_ethernet_interface.untrust.name, panos_loopback_interface.gp.name] }
}

resource "panos_zone" "trust" {
  location = local.tpl_vsys
  name     = "trust"
  network  = { layer3 = [panos_ethernet_interface.trust.name] }
}

resource "panos_zone" "vpn" {
  location = local.tpl_vsys
  name     = "vpn"
  network  = { layer3 = [panos_tunnel_interface.gp.name] }
}

###############################################################################
# Virtual router (single VR — TGW appliance mode handles flow symmetry)
###############################################################################
resource "panos_virtual_router" "vr" {
  location = local.tpl_loc
  name     = var.virtual_router_name
  interfaces = [
    panos_ethernet_interface.untrust.name,
    panos_ethernet_interface.trust.name,
    panos_tunnel_interface.gp.name,
    panos_loopback_interface.gp.name,
  ]
}

# default + internal next hops are the AWS subnet .1 gateways, which DIFFER per
# region (untrust A 10.10.10.1 / B 10.20.10.1; trust A 10.10.20.1 / B 10.20.20.1).
# In a shared template they MUST be template variables overridden per-device, or
# Region B firewalls inherit Region A's gateways and can't route (a Region B
# default route pointing at 10.10.10.1 leaves GP responses with no path to the
# internet and the portal times out). Same per-region-variable pattern as the floating IP.
resource "panos_template_variable" "untrust_gw_default" {
  location = local.tpl_loc
  name     = var.untrust_gw_variable_name
  type     = { ip_netmask = var.untrust_gateway_ip }
}
resource "panos_template_variable" "trust_gw_default" {
  location = local.tpl_loc
  name     = var.trust_gw_variable_name
  type     = { ip_netmask = var.trust_gateway_ip }
}

resource "panos_virtual_router_static_route_ipv4" "default" {
  location       = local.tpl_loc
  virtual_router = panos_virtual_router.vr.name
  name           = "default-to-igw"
  destination    = "0.0.0.0/0"
  interface      = panos_ethernet_interface.untrust.name
  nexthop        = { ip_address = var.untrust_gw_variable_name }
}

resource "panos_virtual_router_static_route_ipv4" "internal" {
  location       = local.tpl_loc
  virtual_router = panos_virtual_router.vr.name
  name           = "internal-to-tgw"
  destination    = var.internal_supernet
  interface      = panos_ethernet_interface.trust.name
  nexthop        = { ip_address = var.trust_gw_variable_name }
}

###############################################################################
# NAT policy (device group)
#   - outbound: trust/vpn -> untrust, source NAT to the untrust interface
#   - inbound app: untrust -> app_dnat_public_ip DNAT to the spoke Apache host
###############################################################################
resource "panos_nat_policy" "rules" {
  location = local.dg_loc

  rules = [
    {
      name                  = "outbound-snat"
      source_zones          = ["trust", "vpn"]
      destination_zone      = ["untrust"]
      source_addresses      = ["any"]
      destination_addresses = ["any"]
      service               = "any"
      nat_type              = "ipv4"
      source_translation = {
        dynamic_ip_and_port = {
          # interface_address (even with an explicit `ip`) requires that IP
          # to be configured on the interface itself, which PAN-OS refuses
          # when DHCP client is enabled ("DHCP interface IP address must be
          # empty"). translated_address has no such requirement — it's just
          # the literal NAT pool. Without this, PAN-OS SNATs to the
          # interface's DHCP-leased primary address, which has no EIP:
          # outbound packets reach the IGW and are silently dropped (no
          # public address to translate to), so replies never come back.
          # Use the floating IP instead, the Elastic-IP-backed address.
          translated_address = [var.app_dnat_public_ip]
        }
      }
    },
    {
      # GlobalProtect clients reaching INTERNAL resources (vpn -> trust: the
      # spokes, AD DC for DNS, etc.). The GP client IP pool (gp_ip_pool, e.g.
      # 10.10.200.0/24) sits inside the security VPC CIDR, so AWS treats return
      # traffic to it as VPC-local and drops it (no ENI owns those addresses) —
      # DNS queries reach the DC but the replies never come back, so GP clients
      # can't resolve names or reach internal services. SNAT the pool to the
      # trust interface's own (routable) IP so replies return to the firewall and
      # are un-NATed back into the tunnel. Symmetric (out and back via trust), so
      # no asymmetric-return drop. (The outbound-snat rule above only covers
      # vpn -> untrust; internet itself is split-tunneled direct from the client.)
      name                  = "gp-internal-snat"
      source_zones          = ["vpn"]
      destination_zone      = ["trust"]
      source_addresses      = ["any"]
      destination_addresses = ["any"]
      service               = "any"
      nat_type              = "ipv4"
      source_translation = {
        dynamic_ip_and_port = {
          interface_address = { interface = panos_ethernet_interface.trust.name }
        }
      }
    },
    {
      name                  = "inbound-app-dnat"
      source_zones          = ["untrust"]
      destination_zone      = ["untrust"]
      source_addresses      = ["any"]
      destination_addresses = ["${var.app_dnat_public_ip}/32"]
      service               = "service-http"
      nat_type              = "ipv4"
      destination_translation = {
        translated_address = var.app_private_ip
      }
      # SNAT the inbound app traffic to the firewall's trust IP as well. WHY:
      # CloudFront -> the internet-facing NLB -> targets the FW untrust IP -> this
      # DNAT -> Apache. With destination-NAT only, Apache replies straight to the
      # NLB node's IP (same security VPC) — the reply is delivered locally and
      # BYPASSES the firewall's un-NAT, so the NLB sees a reply from the wrong
      # source and drops it (client connections time out; only the TCP health
      # check, which is source=NLB-node either way, passes). Source-NAT to the
      # trust interface makes Apache reply to the firewall, which un-NATs and
      # returns via the NLB. Symmetric return.
      source_translation = {
        dynamic_ip_and_port = {
          interface_address = { interface = panos_ethernet_interface.trust.name }
        }
      }
    },
  ]
}

###############################################################################
# Security policy (device group)
###############################################################################
locals {
  # EKS egress-allow rule referencing the EDLs — placed BEFORE spokes-outbound.
  edl_rules = var.enable_edl ? [
    {
      name                  = "eks-egress-edl-allow"
      source_zones          = ["trust"]
      destination_zones     = ["untrust"]
      source_addresses      = ["any"]
      destination_addresses = [panos_external_dynamic_list.eks_fqdn[0].name, panos_external_dynamic_list.eks_ip[0].name]
      applications          = ["any"]
      services              = ["application-default"]
      action                = "allow"
      log_end               = true
    },
  ] : []

  base_rules = [
    {
      name                  = "gp-users-to-internal"
      source_zones          = ["vpn"]
      destination_zones     = ["trust", "untrust"]
      source_addresses      = ["any"]
      destination_addresses = ["any"]
      applications          = ["any"]
      services              = ["application-default"]
      action                = "allow"
      log_end               = true
    },
    {
      name                  = "spokes-outbound"
      source_zones          = ["trust"]
      destination_zones     = ["untrust"]
      source_addresses      = ["any"]
      destination_addresses = ["any"]
      applications          = ["any"]
      services              = ["application-default"]
      action                = "allow"
      log_end               = true
    },
    {
      name                  = "inbound-app"
      source_zones          = ["untrust"]
      destination_zones     = ["trust"]
      source_addresses      = ["any"]
      destination_addresses = [var.app_private_ip]
      applications          = ["web-browsing", "ssl"]
      services              = ["application-default"]
      action                = "allow"
      log_end               = true
    },
    # Inbound GlobalProtect: clients on the internet hit the portal + gateway on
    # the FW's own untrust floating IP (.100:443). That is intrazone untrust->
    # untrust "self" traffic and WOULD be caught by deny-all below
    # (flow_policy_deny: the external SYN reaches the FW but the session goes to
    # DISCARD) — so it needs an explicit allow ahead of deny-all.
    # service-https (443/tcp) covers the portal, the gateway, and the SSL
    # fallback tunnel; the IPSec tunnel (UDP 4501) falls back to SSL if blocked.
    # service-http (80/tcp) is also allowed so PAN-OS's built-in HTTP->HTTPS
    # portal redirect (native + on by default since PAN-OS 8.0) can answer a
    # user who types the bare hostname; without :80 reaching the portal it is
    # silently dropped by deny-all and the browser just hangs (PANW KB
    # kA10g000000ClbeCAC).
    {
      name                  = "gp-portal-gateway-inbound"
      source_zones          = ["untrust"]
      destination_zones     = ["untrust"]
      source_addresses      = ["any"]
      destination_addresses = [for ip in var.gp_local_ips : "${ip}/32"] # each region's floating IP
      applications          = ["any"]
      services              = ["service-https", "service-http"]
      action                = "allow"
      log_end               = true
    },
    {
      name                  = "deny-all"
      source_zones          = ["any"]
      destination_zones     = ["any"]
      source_addresses      = ["any"]
      destination_addresses = ["any"]
      applications          = ["any"]
      services              = ["any"]
      action                = "deny"
      log_end               = true
    },
  ]
}

resource "panos_security_policy" "rules" {
  location = local.dg_loc
  # EDL egress-allow (when enabled) precedes the generic spokes-outbound rule.
  rules = concat(local.edl_rules, local.base_rules)
}
