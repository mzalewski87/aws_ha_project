###############################################################################
# Phase 2a — Panorama configuration orchestration.
#
# Order:
#   1. wait for the Panorama API to answer through the SSM tunnel
#   2. generate the device-registration vm-auth-key -> write
#      ../panorama_vm_auth_key.auto.tfvars (auto-loaded by Phase 1b)
#   3. push the template/DG config via the panos provider (module.panorama_config)
#   4. commit on Panorama + push to the device group / template stack
#
# The panos provider does NOT auto-commit; the commit null_resource does it via
# the XML API. XML-API steps are bash + curl over the tunnel (parity with the
# Azure phase2), delegated to scripts/ for readability.
###############################################################################

locals {
  api_base = "https://${var.panorama_hostname}:${var.panorama_port}"
}

# 1. Wait for the Panorama API to be reachable through the tunnel.
resource "null_resource" "wait_api" {
  triggers = { endpoint = local.api_base }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      for i in $(seq 1 60); do
        if curl -sk -o /dev/null -w '%%{http_code}' "${local.api_base}/php/login.php" | grep -qE '200|302'; then
          echo "Panorama API reachable"; exit 0
        fi
        echo "waiting for Panorama API ($i/60)..."; sleep 15
      done
      echo "Panorama API not reachable via the SSM tunnel — is the port-forward up?" >&2
      exit 1
    EOT
  }
}

# 1b. Activate Panorama: set serial + fetch license (+ device cert via OTP).
# Panorama ships with no serial/license/device-cert. Without them it cannot
# manage firewalls — FWs stay Connected=no even with valid device certs
# (a FW that HAS a device cert only connects to a Panorama that also has one).
# Ported from the Azure project (panorama_activate_license + device cert).
resource "null_resource" "panorama_activate" {
  count = var.panorama_serial_number == "" ? 0 : 1

  triggers = {
    serial = var.panorama_serial_number
    otp    = sha256(var.panorama_device_otp) # re-run when a fresh OTP is supplied
  }

  depends_on = [null_resource.wait_api]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.root}/../scripts/activate-panorama.sh"
    environment = {
      PANORAMA_HOST       = var.panorama_hostname
      PANORAMA_PORT       = tostring(var.panorama_port)
      PANORAMA_USER       = var.panorama_username
      PANORAMA_PASSWORD   = var.panorama_password
      PANORAMA_SERIAL     = var.panorama_serial_number
      PANORAMA_DEVICE_OTP = var.panorama_device_otp
    }
  }
}

# 2. Generate the vm-auth-key and write it for Phase 1b to auto-load.
resource "null_resource" "vm_auth_key" {
  depends_on = [null_resource.wait_api, null_resource.panorama_activate]
  triggers   = { lifetime = var.vm_auth_key_lifetime_hours }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.root}/../scripts/generate-vm-auth-key.sh"
    environment = {
      PANORAMA_HOST     = var.panorama_hostname
      PANORAMA_PORT     = tostring(var.panorama_port)
      PANORAMA_USER     = var.panorama_username
      PANORAMA_PASSWORD = var.panorama_password
      KEY_LIFETIME      = tostring(var.vm_auth_key_lifetime_hours)
      OUTPUT_PATH       = var.vm_auth_key_output_path
    }
  }
}

# 3. Declarative config (template / DG / interfaces / zones / VR / policy / GP).
module "panorama_config" {
  source = "../modules/panorama_config"

  template_name       = var.template_name
  template_stack_name = var.template_stack_name
  device_group_name   = var.device_group_name

  untrust_gateway_ip   = var.untrust_gateway_ip
  trust_gateway_ip     = var.trust_gateway_ip
  mgmt_permitted_cidrs = var.mgmt_permitted_cidrs
  app_dnat_public_ip   = var.app_dnat_public_ip
  app_private_ip       = var.app_private_ip

  fw_untrust_static_ips = var.fw_untrust_static_ips
  untrust_floating_cidr = var.untrust_floating_cidr
  gp_local_ips          = var.gp_local_ips

  # Panorama API connection + GP tunnel interfaces — for the in-module
  # null_resource.gp_tunnel_node that creates the network-side tunnel node
  # BEFORE the GP gateway (one-apply GP deploy).
  panorama_hostname   = var.panorama_hostname
  panorama_port       = var.panorama_port
  panorama_username   = var.panorama_username
  panorama_password   = var.panorama_password
  gp_tunnel_interface = var.gp_tunnel_interface
  gp_local_interface  = var.gp_local_interface

  enable_globalprotect   = var.enable_globalprotect
  gp_gateway_name        = var.gp_gateway_name
  gp_ip_pool             = var.gp_ip_pool
  gp_split_tunnel_routes = var.gp_split_tunnel_routes
  gp_dns_servers         = var.gp_dns_servers
  gp_external_gateways   = var.gp_external_gateways
  gp_server_cert_pem     = var.gp_server_cert_pem
  gp_server_key_pem      = var.gp_server_key_pem
  gp_local_users         = var.gp_local_users

  gp_auth_method           = var.gp_auth_method
  gp_ldap_server_ip        = var.gp_ldap_server_ip
  gp_ldap_extra_server_ips = var.gp_ldap_extra_server_ips
  gp_ldap_base_dn          = var.gp_ldap_base_dn
  gp_ldap_bind_dn          = var.gp_ldap_bind_dn
  gp_ldap_bind_password    = var.gp_ldap_bind_password
  gp_vpn_group             = var.gp_vpn_group

  enable_edl    = var.enable_edl
  edl_server_ip = var.edl_server_ip

  # Serialize the API-mutating steps (parity with Azure phase2): the declarative
  # config push must NOT run concurrently with vm_auth_key / log_collector, or
  # their overlapping API/config-lock work makes panos calls fail with
  # "Session timed out". Run config on a settled Panorama, after those finish.
  depends_on = [null_resource.wait_api, null_resource.vm_auth_key, null_resource.log_collector]
}

# 4b. Log-collector setup (disk-pair + Collector Group bind + commit-all).
resource "null_resource" "log_collector" {
  count      = var.enable_log_collector ? 1 : 0
  depends_on = [null_resource.wait_api, null_resource.panorama_activate]
  triggers   = { restart = tostring(var.log_collector_restart) }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.root}/../scripts/setup-log-collector.sh"
    environment = {
      PANORAMA_HOST     = var.panorama_hostname
      PANORAMA_PORT     = tostring(var.panorama_port)
      PANORAMA_USER     = var.panorama_username
      PANORAMA_PASSWORD = var.panorama_password
      ADD_DISK          = var.log_collector_add_disk ? "yes" : "no"
      DO_RESTART        = var.log_collector_restart ? "yes" : "no"
    }
  }
}

# 3b. Per-device untrust overrides — PRIMARY ($fw_untrust_ip: fw1a .11, fw2a .12,
# fw1b .20.11, fw2b .20.12) and FLOATING ($fw_untrust_floating: Region A .10.100,
# Region B .20.100). Done via the raw XML API because the panos provider can't
# set more than one per-device template-stack variable ("At most 1 occurrence
# for devices/entry"; see scripts/set-untrust-overrides.sh). Runs after the
# config push and before the commit so commit-all carries the correct per-device
# IPs. No-op when var.fw_serials is empty. Two provisioners = two variables.
resource "null_resource" "untrust_ip_overrides" {
  count      = length(var.fw_serials) > 0 ? 1 : 0
  depends_on = [module.panorama_config]
  triggers = {
    serials   = jsonencode(var.fw_serials)
    primaries = jsonencode(var.fw_untrust_static_ips)
    floatings = jsonencode(var.fw_untrust_floating_ips)
    ugws      = jsonencode(var.fw_untrust_gateways)
    tgws      = jsonencode(var.fw_trust_gateways)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.root}/../scripts/set-untrust-overrides.sh"
    environment = {
      PANORAMA_HOST     = var.panorama_hostname
      PANORAMA_PORT     = tostring(var.panorama_port)
      PANORAMA_USER     = var.panorama_username
      PANORAMA_PASSWORD = var.panorama_password
      TEMPLATE_STACK    = var.template_stack_name
      VAR_NAME          = "$fw_untrust_ip"
      FW_OVERRIDES      = jsonencode({ for k, s in var.fw_serials : s => var.fw_untrust_static_ips[k] })
    }
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.root}/../scripts/set-untrust-overrides.sh"
    environment = {
      PANORAMA_HOST     = var.panorama_hostname
      PANORAMA_PORT     = tostring(var.panorama_port)
      PANORAMA_USER     = var.panorama_username
      PANORAMA_PASSWORD = var.panorama_password
      TEMPLATE_STACK    = var.template_stack_name
      VAR_NAME          = "$fw_untrust_floating"
      FW_OVERRIDES      = jsonencode({ for k, s in var.fw_serials : s => var.fw_untrust_floating_ips[k] })
    }
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.root}/../scripts/set-untrust-overrides.sh"
    environment = {
      PANORAMA_HOST     = var.panorama_hostname
      PANORAMA_PORT     = tostring(var.panorama_port)
      PANORAMA_USER     = var.panorama_username
      PANORAMA_PASSWORD = var.panorama_password
      TEMPLATE_STACK    = var.template_stack_name
      VAR_NAME          = "$fw_untrust_gw"
      FW_OVERRIDES      = jsonencode({ for k, s in var.fw_serials : s => var.fw_untrust_gateways[k] })
    }
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.root}/../scripts/set-untrust-overrides.sh"
    environment = {
      PANORAMA_HOST     = var.panorama_hostname
      PANORAMA_PORT     = tostring(var.panorama_port)
      PANORAMA_USER     = var.panorama_username
      PANORAMA_PASSWORD = var.panorama_password
      TEMPLATE_STACK    = var.template_stack_name
      VAR_NAME          = "$fw_trust_gw"
      FW_OVERRIDES      = jsonencode({ for k, s in var.fw_serials : s => var.fw_trust_gateways[k] })
    }
  }
}

# 3c. (GP network-side tunnel node moved INTO module.panorama_config as
# null_resource.gp_tunnel_node, so it runs BEFORE the GP gateway in a single
# apply — see modules/panorama_config/gp.tf.)

# 3d. Download + ACTIVATE the GlobalProtect app package on each firewall, so the
# portal can serve the agent installer (otherwise a portal download yields
# errors.txt "Could not find file" — the package must be activated, not just
# present; PANW KB kA10g000000ClrhCAC). Driven through Panorama's op-command
# proxy (target=serial); firewalls need PANW update-server egress (NAT).
# No-op when GP is off or serials aren't known yet.
resource "null_resource" "gp_client_deploy" {
  count      = var.enable_globalprotect && length(var.fw_serials) > 0 ? 1 : 0
  depends_on = [module.panorama_config, null_resource.untrust_ip_overrides]
  triggers = {
    serials = jsonencode(var.fw_serials)
    version = var.gp_client_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.root}/../scripts/deploy-gp-client.sh"
    environment = {
      PANORAMA_HOST     = var.panorama_hostname
      PANORAMA_PORT     = tostring(var.panorama_port)
      PANORAMA_USER     = var.panorama_username
      PANORAMA_PASSWORD = var.panorama_password
      SERIALS           = join(" ", values(var.fw_serials))
      GP_CLIENT_VERSION = var.gp_client_version
    }
  }
}

# 3e. GP local users with a PROPERLY HASHED password. panos_local_user writes
# plaintext into <phash> without hashing (every login then auth-fails), so the
# users are created here via scripts/set-gp-local-users.sh (openssl passwd -1 ->
# valid MD5-crypt phash in the vsys1 local-user-database). Only for local auth.
resource "null_resource" "gp_local_users" {
  count      = var.enable_globalprotect && var.gp_auth_method == "local" && length(var.gp_local_users) > 0 ? 1 : 0
  depends_on = [module.panorama_config]
  triggers = {
    users = sha256(jsonencode(var.gp_local_users))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.root}/../scripts/set-gp-local-users.sh"
    environment = {
      PANORAMA_HOST     = var.panorama_hostname
      PANORAMA_PORT     = tostring(var.panorama_port)
      PANORAMA_USER     = var.panorama_username
      PANORAMA_PASSWORD = var.panorama_password
      TEMPLATE_NAME     = var.template_name
      GP_LOCAL_USERS    = jsonencode(var.gp_local_users)
    }
  }
}

# 4. Commit on Panorama + push to devices. Runs LAST — after gp_client_deploy too
# — so the long GP-app download doesn't overlap the commit-all (concurrent
# API/job load on one Panorama makes both flaky).
resource "null_resource" "commit" {
  depends_on = [module.panorama_config, null_resource.untrust_ip_overrides, null_resource.gp_client_deploy, null_resource.gp_local_users]
  triggers   = { always = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.root}/../scripts/configure-panorama.sh commit"
    environment = {
      PANORAMA_HOST     = var.panorama_hostname
      PANORAMA_PORT     = tostring(var.panorama_port)
      PANORAMA_USER     = var.panorama_username
      PANORAMA_PASSWORD = var.panorama_password
      DEVICE_GROUP      = var.device_group_name
      TEMPLATE_STACK    = var.template_stack_name
    }
  }
}
