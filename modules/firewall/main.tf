###############################################################################
# modules/firewall — main
#
# 2x VM-Series in a PAN-OS Active/Passive HA pair. ENI order is mandatory for
# PAN-OS boot mapping AND for AWS's own HA requirement:
#   eth0 = mgmt (HA1 control over mgmt), eth1 = ha2 (state sync),
#   eth2 = trust (ethernet1/2), eth3 = untrust (ethernet1/3).
# AWS's VM-Series Deployment Guide states unconditionally (not just as an
# example): "Ethernet1/1 must be assigned as the HA2 link; this is required to
# deploy the VM-Series firewall on AWS in HA." device_index 1 -> ethernet1/1,
# so ha2 (not untrust) must be device_index 1. This was originally backwards
# (untrust=1, ha2=3); fixing it live via detach/reattach-while-stopped was
# attempted and failed empirically -- across 5 attempts (2-ENI swap, internal
# PAN-OS restart, full stop/start, full 3-ENI detach+reattach, plain reboot)
# the PAN-OS dataplane only ever detected 3 of 4 attached ENIs, specifically
# whichever one landed at device_index 3, regardless of which physical ENI
# that was -- so both firewalls had to be recreated with the corrected order
# from launch instead.
# source/dest check is disabled on the dataplane ENIs (untrust/trust) — without
# it the FW cannot forward transit traffic. The untrust floating secondary IP
# on fw1 carries the public EIP (GP portal/gateway + outbound SNAT) and is moved
# to the peer by the HA plugin on failover.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

locals {
  fw_names = ["fw1", "fw2"]

  nic_types = {
    mgmt    = { subnet_id = var.mgmt_subnet_id, subnet_cidr = var.mgmt_subnet_cidr, sg = var.mgmt_sg_id, device_index = 0, dataplane = false }
    ha2     = { subnet_id = var.ha2_subnet_id, subnet_cidr = var.ha2_subnet_cidr, sg = var.ha2_sg_id, device_index = 1, dataplane = true }
    trust   = { subnet_id = var.trust_subnet_id, subnet_cidr = var.trust_subnet_cidr, sg = var.trust_sg_id, device_index = 2, dataplane = true }
    untrust = { subnet_id = var.untrust_subnet_id, subnet_cidr = var.untrust_subnet_cidr, sg = var.untrust_sg_id, device_index = 3, dataplane = true }
  }

  # fw x nic -> ENI definition. fw1's untrust AND trust ENIs get an extra floating
  # secondary IP. The PAN-OS AWS HA plugin (secondary-IP mode) moves the secondary IPs of
  # the failed unit's dataplane ENIs to the peer and, with them, rewrites the route-table
  # entries that point at those ENIs. An ENI without a secondary IP is left alone: with
  # the floating IP on untrust only (as before), the EIP followed every failover but the
  # TGW inspection routes kept pointing at the now-passive unit's trust ENI, black-holing
  # all east-west / spoke traffic. Seen live in path B (PAN-OS 12.2.4, plugin 6.2.1).
  # The PANW guide asks for this too: "Add a secondary IP address to your dataplane
  # interfaces on the first (to be active) HA peer".
  fw_nics = {
    for combo in setproduct(local.fw_names, keys(local.nic_types)) :
    "${combo[0]}-${combo[1]}" => {
      fw           = combo[0]
      nic_type     = combo[1]
      subnet_id    = local.nic_types[combo[1]].subnet_id
      sg           = local.nic_types[combo[1]].sg
      device_index = local.nic_types[combo[1]].device_index
      dataplane    = local.nic_types[combo[1]].dataplane
      private_ips = (contains(["untrust", "trust"], combo[1]) && combo[0] == "fw1") ? [
        cidrhost(local.nic_types[combo[1]].subnet_cidr, var.fw_host_offsets[combo[0]]),
        cidrhost(local.nic_types[combo[1]].subnet_cidr, var.floating_host_offset),
        ] : [
        cidrhost(local.nic_types[combo[1]].subnet_cidr, var.fw_host_offsets[combo[0]])
      ]
    }
  }

  floating_ip       = cidrhost(var.untrust_subnet_cidr, var.floating_host_offset)
  trust_floating_ip = cidrhost(var.trust_subnet_cidr, var.floating_host_offset)
}

data "aws_ami" "vmseries" {
  count       = var.vmseries_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "product-code"
    values = [var.vmseries_product_code]
  }
  filter {
    name   = "name"
    values = ["PA-VM-AWS-${var.vmseries_version}*"]
  }
}

###############################################################################
# Network interfaces (8 total: 4 per FW)
###############################################################################
resource "aws_network_interface" "fw" {
  for_each = local.fw_nics

  subnet_id = each.value.subnet_id
  # ORDERED list: the first address is the PRIMARY. `private_ips` is a SET, so which address
  # AWS made primary was arbitrary — and "10.20.10.100" sorts before "10.20.10.11". Seen live
  # in Region B: fw1's untrust ENI got the FLOATING .100 as its primary and its own .11 as the
  # secondary. The AWS HA plugin moves secondaries and maps primary->primary, so a failover
  # moved .11 (not the floating IP) and put the EIP on fw2's own .12: portal and gateway dead.
  private_ip_list_enabled = true
  private_ip_list         = each.value.private_ips
  security_groups         = [each.value.sg]
  source_dest_check       = each.value.dataplane ? false : true
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-${each.value.fw}-${each.value.nic_type}" })

  # The untrust and trust ENIs carry a floating IP as a SECONDARY address, and the
  # PAN-OS AWS HA plugin moves it between the pair on failover
  # (AssignPrivateIpAddresses). That makes `private_ips` runtime-owned: after a
  # failover Terraform wants to put the floating IP back on fw1, fighting the
  # plugin and stranding the address on the passive unit. The primary IP is set
  # at creation and never changes, so ignoring the lists is safe. (private_ip_list_enabled is
  # ignored too, so ENIs created before the ordered list existed are not touched.)
  lifecycle {
    ignore_changes = [private_ips, private_ip_list, private_ip_list_enabled]
    # Fail loudly if AWS ever made another address the primary (e.g. the floating IP): HA
    # failover would then move the wrong address. Checked on every plan/apply.
    postcondition {
      condition     = self.private_ip == each.value.private_ips[0]
      error_message = "ENI ${each.key}: primary is ${self.private_ip}, expected ${each.value.private_ips[0]}. The floating IP must be a secondary; recreate this ENI and its firewall (docs/DEPLOYMENT-SCM.md, HA failover)."
    }
  }
}

###############################################################################
# Public EIP — the GP portal/gateway entry + outbound SNAT. Bound to fw1's
# untrust floating IP initially; the HA plugin re-associates it on failover.
###############################################################################
resource "aws_eip" "fw_public" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-fw-public" })
}

resource "aws_eip_association" "fw_public" {
  allocation_id        = aws_eip.fw_public.id
  network_interface_id = aws_network_interface.fw["fw1-untrust"].id
  private_ip_address   = local.floating_ip

  # RUNTIME-OWNED BY THE PAN-OS AWS HA PLUGIN. This association only seeds the
  # initial placement on fw1; on every failover the plugin re-associates the EIP
  # onto whichever firewall is active. Terraform therefore sees "drift" after a
  # failover and, on the next apply, REVERTS the EIP to fw1 — moving the public
  # address onto the PASSIVE unit and taking the portal and the app offline
  # until the next failover. Observed on 2026-09-15.
  #
  # Ignore both attributes so Terraform seeds the association and then leaves
  # failover to the plugin, which is the component that actually owns it.
  lifecycle {
    ignore_changes = [network_interface_id, private_ip_address]
  }
}

###############################################################################
# VM-Series instances
###############################################################################
resource "aws_instance" "fw" {
  for_each = toset(local.fw_names)

  # data.aws_ami.vmseries is `most_recent` within the pinned vmseries_version,
  # so PANW republishing a build of the SAME version silently forces
  # REPLACEMENT. Recreating a firewall is expensive and not self-healing: it
  # burns a BYOL activation from the credit pool, and native HA is device-local
  # config that Panorama does NOT push, so the replacement comes back with
  # "HA not enabled" and failover stops working until scripts/configure-ha.sh is
  # re-run for both units (see docs/DEPLOYMENT.md).
  #
  # Upgrade deliberately: bump vmseries_version, then `-replace=` one unit at a
  # time and re-run configure-ha.sh, so the pair is never down together.
  lifecycle {
    ignore_changes = [ami]
  }

  ami                  = coalesce(var.vmseries_ami_id, try(data.aws_ami.vmseries[0].id, null))
  instance_type        = var.instance_type
  iam_instance_profile = var.instance_profile_name
  user_data_base64     = var.user_data_base64[each.key]
  key_name             = var.key_name

  # ENI order maps to PAN-OS interfaces — do not reorder.
  dynamic "network_interface" {
    for_each = {
      for nt, cfg in local.nic_types : nt => cfg.device_index
    }
    content {
      network_interface_id = aws_network_interface.fw["${each.key}-${network_interface.key}"].id
      device_index         = network_interface.value
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 (bootstrap read path)
  }

  # The Marketplace VM-Series AMI's root volume does NOT delete on termination, so every
  # destroy/replace orphaned a 60 GB volume that kept billing (found live: 4 leftovers
  # after one teardown). Make it follow the instance.
  root_block_device {
    delete_on_termination = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}
