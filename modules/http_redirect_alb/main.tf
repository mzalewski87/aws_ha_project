###############################################################################
# modules/http_redirect_alb — HTTP->HTTPS 301 redirect for the GP portal.
#
# WHY THIS EXISTS: the GP portal is HTTPS-only and PAN-OS has no built-in :80
# ->:443 redirect for it, so a user who types the bare portal hostname over
# plain HTTP gets nothing. AWS Global Accelerator is L4 (TCP/UDP) and cannot
# issue an HTTP 301 either. The canonical AWS mechanism for an HTTP->HTTPS
# redirect is an Application Load Balancer listener `redirect` action, and GA
# supports an ALB as an endpoint — so this ALB sits behind the GA :80 listener
# and does nothing but 301 to HTTPS. The GA :443 / UDP-4501 listeners still go
# straight to the firewall EIPs (TLS terminates on the firewall, which owns the
# cert); this ALB never touches real GP traffic.
#
# The redirect is HOST-PRESERVING (`#{host}`), so it works for whatever portal
# FQDN the deployer uses (gp.<domain>, the GA DNS name, or a bare IP) with no
# per-domain config. It has NO target group — a redirect is a listener default
# action; GA health-checks the endpoint at the TCP level (port 80), which an
# ALB always answers, so a target-less redirect ALB stays healthy for GA.
###############################################################################

resource "aws_security_group" "alb" {
  name_prefix = "${var.name_prefix}-gp-redirect-"
  description = "GP portal HTTP-to-HTTPS redirect ALB - allow :80 in"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from anywhere (redirected to HTTPS); reached via Global Accelerator"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "allow all egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-gp-redirect-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-gp-redirect"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-gp-redirect" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = tostring(var.https_port)
      host        = "#{host}"
      path        = "/#{path}"
      query       = "#{query}"
      status_code = "HTTP_301"
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-gp-redirect-http" })
}
