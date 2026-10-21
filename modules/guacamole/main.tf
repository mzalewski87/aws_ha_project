###############################################################################
# modules/guacamole — Apache Guacamole RDP gateway (clientless, browser-based)
#
# Secure, auditable access to the domain controller for BOTH management paths
# (Panorama / SCM): users hit https://<fqdn> (ALB, ACM cert), log in with
# password + TOTP, and Guacamole proxies RDP to the DC over the TGW — i.e.
# THROUGH the firewalls, so the session is inspected and logged. No RDP port is
# ever exposed to the internet.
#
#   internet -> ALB :443 (ACM) -> Guacamole host :8080 (Docker: guacamole +
#   guacd + PostgreSQL) -> TGW -> VM-Series -> DC :3389
#
# Public exposure is deliberate (unrestricted ALB by default), so the controls
# are: mandatory TOTP, generated admin password in Secrets Manager (default
# guacadmin removed), IMDSv2, encrypted EBS, SSM-only host access (no SSH SG).
###############################################################################

terraform {
  required_providers {
    aws    = { source = "hashicorp/aws" }
    random = { source = "hashicorp/random" }
  }
}

data "aws_region" "current" {}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "random_password" "ldap_bind" {
  count   = var.ldap_enabled ? 1 : 0
  length  = 24
  special = false
}

locals {
  ldap_base_dn = join(",", [for p in split(".", var.ldap_domain) : "DC=${p}"])
}

resource "aws_secretsmanager_secret" "admin" {
  name                    = "${var.name_prefix}-guacamole-admin"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id
  secret_string = jsonencode(merge({
    username     = var.guacamole_admin_user
    password     = random_password.admin.result
    db_password  = random_password.db.result
    rdp_password = var.rdp_password
  }, var.ldap_enabled ? { ldap_bind_password = random_password.ldap_bind[0].result } : {}))

  lifecycle {
    precondition {
      condition     = !var.ldap_enabled || (var.ldap_domain != "" && can(regex("^[A-Za-z0-9._-]+$", var.ldap_group)) && can(regex("^[A-Za-z0-9._-]+$", var.ldap_bind_user)))
      error_message = "ldap_enabled needs ldap_domain, and ldap_group / ldap_bind_user without spaces or special characters."
    }
  }
}

# --- Security groups --------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-guac-alb"
  description = "Guacamole ALB: 443 (and 80 for the HTTPS redirect)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-guac-alb" })

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.alb_ingress_cidrs
  }
  ingress {
    description = "HTTP (redirect only)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.alb_ingress_cidrs
  }
  egress {
    description     = "To Guacamole host"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.host.id]
  }
}

resource "aws_security_group" "host" {
  name        = "${var.name_prefix}-guac-host"
  description = "Guacamole host: 8080 from ALB only; no SSH (SSM)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-guac-host" })

  egress {
    description = "All outbound (image pulls, SSM, RDP to the DC via TGW)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "host_from_alb" {
  type                     = "ingress"
  description              = "Guacamole web from ALB"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.host.id
  source_security_group_id = aws_security_group.alb.id
}

# --- IAM (SSM + read own secret) -------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name               = "${var.name_prefix}-guacamole"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "secret" {
  name = "read-guacamole-secret"
  role = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.admin.arn
    }]
  })
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.name_prefix}-guacamole"
  role = aws_iam_role.host.name
  tags = var.tags
}

# --- Host -------------------------------------------------------------------
resource "aws_instance" "guac" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = var.host_subnet_id
  vpc_security_group_ids = [aws_security_group.host.id]
  iam_instance_profile   = aws_iam_instance_profile.host.name
  key_name               = var.key_name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  root_block_device {
    volume_size = 30
    encrypted   = true
  }

  # No secrets here: the script fetches them from Secrets Manager with the
  # instance role, so they never land in user-data (readable via the API).
  user_data = templatefile("${path.module}/templates/user-data.sh.tpl", {
    region            = data.aws_region.current.region
    secret_id         = aws_secretsmanager_secret.admin.id
    admin_user        = var.guacamole_admin_user
    rdp_target_name   = var.rdp_target_name
    rdp_target_host   = var.rdp_target_host
    rdp_target_domain = var.rdp_target_domain
    rdp_username      = var.rdp_username
    ldap_enabled      = var.ldap_enabled
    ldap_group        = var.ldap_group
    ldap_base_dn      = local.ldap_base_dn
    ldap_bind_dn      = "CN=${var.ldap_bind_user},CN=Users,${local.ldap_base_dn}"
  })
  user_data_replace_on_change = true

  # The AMI comes from the always-latest AL2023 parameter: without this every new AL2023
  # release would replace the host and wipe its PostgreSQL (users, TOTP enrolments).
  lifecycle {
    ignore_changes = [ami]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-guacamole" })

  depends_on = [aws_secretsmanager_secret_version.admin]
}

# --- ALB --------------------------------------------------------------------
resource "aws_lb" "this" {
  name               = "${var.name_prefix}-guac"
  load_balancer_type = "application"
  internal           = false
  subnets            = var.alb_subnet_ids
  security_groups    = [aws_security_group.alb.id]
  idle_timeout       = 3600 # long-lived websocket/tunnel sessions

  drop_invalid_header_fields = true
  tags                       = var.tags
}

resource "aws_lb_target_group" "this" {
  name     = "${var.name_prefix}-guac"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path    = "/guacamole/"
    matcher = "200"
  }
  stickiness {
    type    = "lb_cookie"
    enabled = true
  }
  tags = var.tags
}

resource "aws_lb_target_group_attachment" "this" {
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = aws_instance.guac.id
  port             = 8080
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  # Bare "/" -> the Guacamole webapp context.
  default_action {
    type = "redirect"
    redirect {
      status_code = "HTTP_301"
      path        = "/guacamole/"
      port        = "443"
      protocol    = "HTTPS"
    }
  }
}

resource "aws_lb_listener_rule" "app" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
  condition {
    path_pattern {
      values = ["/guacamole", "/guacamole/*"]
    }
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      status_code = "HTTP_301"
      port        = "443"
      protocol    = "HTTPS"
    }
  }
}
