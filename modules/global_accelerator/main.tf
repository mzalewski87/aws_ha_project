###############################################################################
# modules/global_accelerator — main
#
# One accelerator, one listener per protocol/port, and one endpoint group per
# region per listener (endpoint = that region's FW public EIP). GA runs its own
# health checks against EIP endpoints (TCP 443) and fails the portal over to a
# healthy region in under a minute.
#
# Must be created against the us-west-2 provider (GA control plane) — the root
# passes providers = { aws = aws.global }.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

locals {
  # One (listener, region) pair per endpoint group. The HTTP-redirect listener
  # (:80) points at that region's redirect ALB when one is supplied
  # (redirect_alb_arn) so it can issue the 301; every other listener — and the
  # :80 listener when no ALB is given — points at the firewall EIP as before.
  groups = merge([
    for li, l in var.listeners : {
      for eg in var.endpoint_groups :
      "${l.protocol}-${l.port}-${eg.region}" => {
        listener_key = "${l.protocol}-${l.port}"
        region       = eg.region
        use_alb      = try(l.http_redirect, false) && try(eg.redirect_alb_arn, "") != "" && try(eg.redirect_alb_arn, null) != null
        # endpoint_id resolved below so the ternary reads cleanly.
        eip_allocation_id = eg.eip_allocation_id
        redirect_alb_arn  = try(eg.redirect_alb_arn, null)
        # ALB listens on the listener port; EIP groups health-check on 443.
        health_check_port = (try(l.http_redirect, false) && try(eg.redirect_alb_arn, "") != "" && try(eg.redirect_alb_arn, null) != null) ? l.port : var.health_check_port
      }
    }
  ]...)
}

resource "aws_globalaccelerator_accelerator" "this" {
  name            = "${var.name_prefix}-gp-portal"
  ip_address_type = "IPV4"
  enabled         = true
  tags            = merge(var.tags, { Name = "${var.name_prefix}-gp-portal" })
}

resource "aws_globalaccelerator_listener" "this" {
  for_each = { for l in var.listeners : "${l.protocol}-${l.port}" => l }

  accelerator_arn = aws_globalaccelerator_accelerator.this.arn
  protocol        = each.value.protocol
  client_affinity = "SOURCE_IP"

  port_range {
    from_port = each.value.port
    to_port   = each.value.port
  }
}

resource "aws_globalaccelerator_endpoint_group" "this" {
  for_each = local.groups

  listener_arn                  = aws_globalaccelerator_listener.this[each.value.listener_key].arn
  endpoint_group_region         = each.value.region
  health_check_protocol         = "TCP"
  health_check_port             = each.value.health_check_port
  health_check_interval_seconds = 10
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id = each.value.use_alb ? each.value.redirect_alb_arn : each.value.eip_allocation_id
    weight      = 128
    # ALB endpoints preserve the client IP by default; harmless for a redirect.
    client_ip_preservation_enabled = each.value.use_alb ? true : null
  }
}
