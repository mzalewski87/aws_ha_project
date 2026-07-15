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

resource "aws_lb" "app" {
  name                             = "${var.name_prefix}-app-nlb"
  load_balancer_type               = "network"
  internal                         = false
  subnets                          = var.subnet_ids
  enable_cross_zone_load_balancing = true
  tags                             = merge(var.tags, { Name = "${var.name_prefix}-app-nlb" })
}

# One target group + listener per TCP port; all point at the FW untrust IPs.
resource "aws_lb_target_group" "app" {
  for_each = toset([for p in var.listeners : tostring(p)])

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
    for pair in setproduct([for p in var.listeners : tostring(p)], var.target_ips) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], ip = pair[1] }
  }

  target_group_arn = aws_lb_target_group.app[each.value.port].arn
  target_id        = each.value.ip
  port             = tonumber(each.value.port)
}

resource "aws_lb_listener" "app" {
  for_each = toset([for p in var.listeners : tostring(p)])

  load_balancer_arn = aws_lb.app.arn
  port              = tonumber(each.key)
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[each.key].arn
  }
}
