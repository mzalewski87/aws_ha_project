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

  # fw x nic -> ENI definition. fw1's untrust ENI gets the extra floating IP.
  fw_nics = {
    for combo in setproduct(local.fw_names, keys(local.nic_types)) :
    "${combo[0]}-${combo[1]}" => {
      fw           = combo[0]
      nic_type     = combo[1]
      subnet_id    = local.nic_types[combo[1]].subnet_id
      sg           = local.nic_types[combo[1]].sg
      device_index = local.nic_types[combo[1]].device_index
      dataplane    = local.nic_types[combo[1]].dataplane
      private_ips = (combo[1] == "untrust" && combo[0] == "fw1") ? [
        cidrhost(local.nic_types[combo[1]].subnet_cidr, var.fw_host_offsets[combo[0]]),
        cidrhost(local.nic_types[combo[1]].subnet_cidr, var.floating_host_offset),
        ] : [
        cidrhost(local.nic_types[combo[1]].subnet_cidr, var.fw_host_offsets[combo[0]])
      ]
    }
  }

  floating_ip = cidrhost(var.untrust_subnet_cidr, var.floating_host_offset)
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

  subnet_id         = each.value.subnet_id
  private_ips       = each.value.private_ips
  security_groups   = [each.value.sg]
  source_dest_check = each.value.dataplane ? false : true
  tags              = merge(var.tags, { Name = "${var.name_prefix}-${each.value.fw}-${each.value.nic_type}" })
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
}

###############################################################################
# VM-Series instances
###############################################################################
resource "aws_instance" "fw" {
  for_each = toset(local.fw_names)

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

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}
