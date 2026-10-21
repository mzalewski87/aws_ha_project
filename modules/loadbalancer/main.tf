###############################################################################
# modules/loadbalancer — main
#
# Public Network Load Balancer in front of the FW untrust ENIs (LB sandwich).
# Cross-zone LB is enabled so NLB nodes in any AZ can reach the single-AZ
# Active/Passive FW targets.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

# CloudFront is the only intended client of this NLB. With cloudfront_only the NLB gets a
# security group that admits only CloudFront's origin-facing ranges (AWS-managed prefix list),
# so the app cannot be reached around CloudFront (and its WAF). NLB security groups can only be
# set when the NLB is created: turning this on replaces the NLB (CloudFront follows the new name).
data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = var.cloudfront_only ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "nlb" {
  count       = var.cloudfront_only ? 1 : 0
  name        = "${var.name_prefix}-app-nlb"
  description = "App NLB: CloudFront origin-facing ranges on the origin port only"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-app-nlb" })

  # Only the port(s) CloudFront actually uses towards this origin: the managed prefix list counts
  # as ~55 rules per port against the 60-rule SG limit, so one rule per listener does not fit.
  dynamic "ingress" {
    for_each = toset([for p in var.cloudfront_origin_ports : tostring(p)])
    content {
      description     = "CloudFront origin-facing"
      from_port       = tonumber(ingress.value)
      to_port         = tonumber(ingress.value)
      protocol        = "tcp"
      prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront[0].id]
    }
  }
  egress {
    description = "To the firewall targets and health checks"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "app" {
  name                             = "${var.name_prefix}-app-nlb"
  load_balancer_type               = "network"
  internal                         = false
  subnets                          = var.subnet_ids
  enable_cross_zone_load_balancing = true
  security_groups                  = var.cloudfront_only ? [aws_security_group.nlb[0].id] : null
  tags                             = merge(var.tags, { Name = "${var.name_prefix}-app-nlb" })
}

# One target group + listener per TCP port; all point at the FW untrust IPs.
locals {
  # With cloudfront_only nothing but CloudFront may reach the NLB, so only its origin port exists.
  listener_ports = toset([for p in(var.cloudfront_only ? var.cloudfront_origin_ports : var.listeners) : tostring(p)])
}

resource "aws_lb_target_group" "app" {
  for_each = local.listener_ports

  name        = "${var.name_prefix}-app-tg-${each.key}"
  port        = tonumber(each.key)
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "TCP"
    port     = tostring(var.health_check_port)
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-tg-${each.key}" })
}

resource "aws_lb_target_group_attachment" "app" {
  for_each = {
    for pair in setproduct(tolist(local.listener_ports), var.target_ips) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], ip = pair[1] }
  }

  target_group_arn = aws_lb_target_group.app[each.value.port].arn
  target_id        = each.value.ip
  port             = tonumber(each.value.port)
}

resource "aws_lb_listener" "app" {
  for_each = local.listener_ports

  load_balancer_arn = aws_lb.app.arn
  port              = tonumber(each.key)
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[each.key].arn
  }
}
