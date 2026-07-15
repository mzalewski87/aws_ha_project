###############################################################################
# modules/panorama_config — GlobalProtect (panos v2)
#
# The north-star deliverable: GP Portal + Gateway on the A/P HA pair. Gated by
# var.enable_globalprotect because it needs a real server certificate. Baseline
# auth is a local database — swap for SAML/LDAP in production (see the auth
# profile method block). Multi-region: the portal's external gateway list
# (var.gp_external_gateways) advertises every region; Region B is appended in
# Phase R2. Gateway failover is GP-native (agent picks best-available).
###############################################################################

locals {
  gp_count       = var.enable_globalprotect ? 1 : 0
  gp_ldap_count  = var.enable_globalprotect && var.gp_auth_method == "ldap" ? 1 : 0
  gp_local_count = var.enable_globalprotect && var.gp_auth_method == "local" ? 1 : 0
  # A ternary directly inside the "method" object attribute confuses the panos
  # provider's nested-object type unification (two differently-shaped object
  # literals in one conditional); use two separate resources instead (below)
  # and pick the active one's name here — a plain string ternary is safe.
  gp_auth_profile_ref = var.gp_auth_method == "ldap" ? try(panos_authentication_profile.gp_ldap[0].name, "") : try(panos_authentication_profile.gp_local[0].name, "")

  # Group-gated GP access: only members of the vpnusers AD group may connect.
  # Enabled only for LDAP auth with a base DN set (a group DN needs it), so it
  # never self-locks a local-auth or base-DN-less deploy. The DN is lowercased to
  # match how PAN-OS group-mapping normalizes group DNs, so the auth allow-list
  # comparison is exact.
  gp_group_gate = var.enable_globalprotect && var.gp_auth_method == "ldap" && var.gp_ldap_base_dn != ""
  gp_group_dn   = lower("cn=${var.gp_vpn_group},cn=users,${var.gp_ldap_base_dn}")
  # NetBIOS domain (first DC= label of the base DN, e.g. "DC=panw,DC=labs" ->
  # "panw"). Group-mapping stores members as DOMAIN\sam (panw\admin), but a GP
  # user logs in with the bare sAMAccountName. Setting user_domain on the auth
  # profile qualifies the login to DOMAIN\user so the allow-list group check
  # matches — without it, group-gated auth rejects even valid members.
  gp_user_domain = local.gp_group_gate ? lower(regex("^[Dd][Cc]=([^,]+)", var.gp_ldap_base_dn)[0]) : null
}

# Server certificate (public CA or exported ACM cert — PAN-OS cannot consume ACM).
resource "panos_certificate_import" "gp" {
  count    = local.gp_count
  location = { template = { name = var.template_name } }
  name     = var.gp_server_cert_name

  local = {
    pem = {
      certificate = var.gp_server_cert_pem
      private_key = var.gp_server_key_pem
    }
  }
}

resource "panos_ssl_tls_service_profile" "gp" {
  count       = local.gp_count
  location    = { template = { name = var.template_name } }
  name        = "gp-ssl-tls"
  certificate = panos_certificate_import.gp[0].name

  protocol_settings = {
    # Explicit max_version: the provider's "max" default (its documented
    # default keyword) is rejected by this PAN-OS/content version
    # ("max-version 'max' is not an allowed keyword") -- pin both ends to
    # TLS 1.2 instead of relying on the computed default.
    min_version = "tls1-2"
    max_version = "tls1-2"
  }
}

# Auth: local database (default, baseline) or LDAP against the spoke2 AD DC
# (gp_auth_method = "ldap" — promote the DC first, see modules/spoke2_dc).
# SAML is a further option not wired here.
resource "panos_ldap_profile" "ad" {
  count    = local.gp_ldap_count
  location = { template = { name = var.template_name } }
  name     = "gp-ad-ldap"

  ldap_type     = "active-directory"
  base          = var.gp_ldap_base_dn
  bind_dn       = var.gp_ldap_bind_dn
  bind_password = var.gp_ldap_bind_password
  ssl           = false

  # LOW connect timeout is load-bearing for region-outage failover. The server
  # list below is template-wide (one template for both regions), so a firewall in
  # the SURVIVING region still tries the first-listed DC first. If that DC is in
  # the dead region, PAN-OS must give up and move to the next server FAST — before
  # the GlobalProtect getconfig auth times out — or login just fails during an
  # outage. bind_timelimit caps the per-server TCP connect wait (default 3s here
  # vs PAN-OS's 30s), so auth fails over to the surviving-region DC within a few
  # seconds. With AD multi-master replication both DCs hold the same accounts, so
  # either one authenticates. (retry_interval keeps a downed server from being
  # retried too eagerly.)
  bind_timelimit = var.gp_ldap_bind_timelimit
  timelimit      = var.gp_ldap_search_timelimit
  retry_interval = var.gp_ldap_retry_interval

  # One entry per domain controller. Listing BOTH regions' DCs makes GP LDAP
  # resilient to a region outage: PAN-OS tries them in order and fails over (fast,
  # thanks to bind_timelimit above), and with AD replication both DCs hold the
  # same accounts. Region A's DC is gp_ldap_server_ip; add the Region B DC via
  # gp_ldap_extra_server_ips.
  servers = [
    for idx, ip in concat([var.gp_ldap_server_ip], var.gp_ldap_extra_server_ips) :
    { name = "dc${idx + 1}", address = ip, port = 389 }
  ]
}

# The two auth profiles get DISTINCT PAN-OS names (suffix -local / -ldap) so
# switching gp_auth_method never collides on a shared name. If both used the same
# name, Terraform's destroy(old)+create(new) would fail: the profile can't be
# deleted while the portal/gateway still reference it, and the create hits "entry
# already exists". With distinct names the new one is created first, the
# portal/gateway repoint to it (local.gp_auth_profile_ref), and the old one —
# now unreferenced — deletes cleanly.
# Auth profiles live in the SAME location as the local-user-database (vsys1) and
# the GP portal/gateway that reference them. A template-SHARED local-database
# auth profile cannot see a vsys1 local user (the user is created at vsys1 —
# shared local-user-database isn't a valid schema node), so a shared profile
# authenticates against an empty shared DB and every login returns auth-failed
# (HTTP 512, X-Private-Pan-Globalprotect: auth-failed) — both local and ldap
# logins fail if the profile is shared while the user/portal are vsys1. Pin the
# profiles to template_vsys.
resource "panos_authentication_profile" "gp_local" {
  count      = local.gp_local_count
  location   = local.gp_tpl_vsys
  name       = "${var.gp_auth_profile_name}-local"
  allow_list = ["all"]

  method = {
    local_database = {}
  }
}

resource "panos_authentication_profile" "gp_ldap" {
  count    = local.gp_ldap_count
  location = local.gp_tpl_vsys
  name     = "${var.gp_auth_profile_name}-ldap"
  # Gate GP access on the vpnusers AD group (resolved by the group-mapping below).
  # Without a base DN there is no group DN to gate on, so fall back to "all" — a
  # bad group DN would otherwise lock out every LDAP login.
  allow_list = local.gp_group_gate ? [local.gp_group_dn] : ["all"]
  # Qualifies the bare sAMAccountName login to DOMAIN\user so the allow-list
  # group-membership check matches (group-mapping stores members as DOMAIN\user).
  user_domain = local.gp_user_domain

  method = {
    ldap = {
      server_profile  = panos_ldap_profile.ad[0].name
      login_attribute = "sAMAccountName"
    }
  }
}

# LDAP group-mapping so PAN-OS resolves vpnusers membership (the auth allow-list
# above gates on it). The panos provider has no resource for group-mapping, so
# it's set via the raw XML API — same pattern as null_resource.gp_tunnel_node.
# AD replication makes the group valid in both regions; the shared template
# pushes this mapping to both firewall pairs.
resource "null_resource" "gp_group_mapping" {
  count = local.gp_group_gate ? 1 : 0
  triggers = {
    group_dn = local.gp_group_dn
    profile  = panos_ldap_profile.ad[0].name
    template = var.template_name
    vsys     = var.vsys
  }
  depends_on = [panos_ldap_profile.ad]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/../../scripts/set-group-mapping.sh"
    environment = {
      PANORAMA_HOST     = var.panorama_hostname
      PANORAMA_PORT     = tostring(var.panorama_port)
      PANORAMA_USER     = var.panorama_username
      PANORAMA_PASSWORD = var.panorama_password
      TEMPLATE_NAME     = var.template_name
      VSYS              = var.vsys
      MAP_NAME          = "gp-group-map"
      LDAP_PROFILE      = panos_ldap_profile.ad[0].name
      GROUP_DN          = local.gp_group_dn
    }
  }
}

# GP local users are created by scripts/set-gp-local-users.sh (null_resource.
# gp_local_users in phase2), NOT by panos_local_user: that resource writes its
# `password` VERBATIM into <phash> without hashing, so a plaintext password is
# stored as the hash and every login fails auth. The script hashes with
# `openssl passwd -1` and sets a valid <phash> in the vsys1 local-user-database.
# (Users live in vsys1 — a template-only/shared local-user-database isn't a valid
# schema node, and a shared auth profile can't see a vsys1 user either.)

###############################################################################
# GP network-side tunnel node (network/tunnel/global-protect-gateway) — the
# tunnel-mode gateway's remote-user-tunnel cross-references it, and the panos
# provider has NO model for it, so it's set via the XML API. It MUST exist
# BEFORE panos_globalprotect_gateway.gw is created, or the gateway create fails
# with "remote-user-tunnel 'tunnel.1' is not a valid reference". Creating it
# here, inside the module, ordered after
# the tunnel interface and before the gateway, makes a fresh deploy work in ONE
# apply (no manual out-of-band step). See scripts/set-gp-tunnel-node.sh.
resource "null_resource" "gp_tunnel_node" {
  count = local.gp_count
  triggers = {
    node     = "${var.gp_gateway_name}-tun"
    tunnel   = var.gp_tunnel_interface
    local_if = var.gp_local_interface
    template = var.template_name
  }
  depends_on = [panos_tunnel_interface.gp]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/../../scripts/set-gp-tunnel-node.sh"
    environment = {
      PANORAMA_HOST     = var.panorama_hostname
      PANORAMA_PORT     = tostring(var.panorama_port)
      PANORAMA_USER     = var.panorama_username
      PANORAMA_PASSWORD = var.panorama_password
      TEMPLATE_NAME     = var.template_name
      NODE_NAME         = "${var.gp_gateway_name}-tun"
      TUNNEL_INTERFACE  = var.gp_tunnel_interface
      LOCAL_INTERFACE   = var.gp_local_interface
    }
  }
}

###############################################################################
# GlobalProtect Gateway (this region's tunnel terminator)
###############################################################################
resource "panos_globalprotect_gateway" "gw" {
  count                   = local.gp_count
  location                = local.gp_tpl_vsys
  name                    = var.gp_gateway_name
  ssl_tls_service_profile = panos_ssl_tls_service_profile.gp[0].name
  tunnel_mode             = true
  depends_on              = [null_resource.gp_tunnel_node]
  # remote_user_tunnel is the tunnel interface. It is a CROSS-REFERENCE to a
  # <tunnel-interface> bound in the network-side node
  # (network/tunnel/global-protect-gateway) which the panos provider CANNOT
  # create — that node is set out-of-band by scripts/set-gp-tunnel-node.sh
  # (phase2 null_resource.gp_tunnel_node). Setting this without that node makes
  # PAN-OS reject it ("not a valid reference") and fail the whole
  # commit with the misleading "<local-address> tag does not exist" (the
  # tunnel's local-address lives in that node). With the node present this
  # resolves. See PANW KB kA14u000000sY3CCAU.
  remote_user_tunnel = panos_tunnel_interface.gp.name

  # Bind to the shared untrust floating IP (.100/24) — the address that carries
  # the public EIP and moves between firewalls on failover (AWS HA plugin). It
  # is declared as a static secondary on the untrust interface (see main.tf), so
  # PAN-OS resolves this reference. The panos provider's schema forces exactly
  # one of ip/floating_ip here (interface-only is rejected at plan by the
  # provider even though PAN-OS itself accepts it); `floating_ip` is the HA
  # Active-Active construct and is invalid under Active/Passive, so we use `ip`.
  # The address MUST exist on the interface config or PAN-OS rejects it with
  # "not a valid reference" (a DHCP interface with no static IP will not work).
  local_address = {
    interface = panos_ethernet_interface.untrust.name
    ip        = { ipv4 = var.untrust_floating_variable_name }
  }

  client_auth = [{
    name                   = "default"
    authentication_profile = local.gp_auth_profile_ref
    os                     = "Any"
  }]

  remote_user_tunnel_configs = [{
    name       = "gp-tunnel-config"
    ip_pool    = var.gp_ip_pool
    dns_server = var.gp_dns_servers
    split_tunneling = {
      access_route = var.gp_split_tunnel_routes
    }
  }]
}

###############################################################################
# GlobalProtect Portal (config + external gateway list = multi-region failover)
###############################################################################
resource "panos_globalprotect_portal" "portal" {
  count    = local.gp_count
  location = local.gp_tpl_vsys
  name     = var.gp_portal_name

  portal_config = {
    ssl_tls_service_profile = panos_ssl_tls_service_profile.gp[0].name
    # See the gateway's local_address comment above — bind to the floating IP.
    local_address = {
      interface = panos_ethernet_interface.untrust.name
      ip        = { ipv4 = var.untrust_floating_variable_name }
    }
    client_auth = [{
      name                   = "default"
      authentication_profile = local.gp_auth_profile_ref
      os                     = "Any"
    }]
  }

  client_config = {
    configs = [{
      name = "default"
      gateways = {
        external = {
          # An external gateway address may be an FQDN (normal, multi-region:
          # resolves to each region's EIP / Global Accelerator) OR a bare IP
          # (single-region demo). They go in DIFFERENT PAN-OS fields — putting an
          # IP in <fqdn> fails the firewall commit with "fqdn <ip> is invalid"
          # (gp_broker phase 1 failure). Detect and route accordingly.
          list = [for gw in var.gp_external_gateways : {
            name          = gw.name
            fqdn          = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", gw.address)) ? null : gw.address
            ip            = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", gw.address)) ? { ipv4 = gw.address } : null
            priority_rule = [{ name = "Any", priority = gw.priority }]
          }]
        }
      }
    }]
  }
}
