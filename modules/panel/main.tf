###############################################################################
# modules/panel — lab admin panel (read-only), redundant across AZs
#
#   internet -> ALB :443 (ACM) -> panel host :8080 (one per AZ; gunicorn + Flask)
#                                   |-> LDAP :389 -> DC (AD login, group panel-admins)
#                                   '-> HTTPS :443 -> firewall mgmt IPs (read-only admin)
#
# Lives in the management VPC, i.e. OUTSIDE the firewall data path it reports on:
# failing a firewall over does not take the panel down. Two hosts in two AZs
# behind one ALB, so losing a host or an AZ keeps the panel reachable.
# The panel only READS (HA state, policy simulation); it has no IAM right to touch
# EC2 and no write-capable firewall account. Secrets come from Secrets Manager.
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

resource "random_password" "session" {
  length  = 48
  special = false
}

resource "random_password" "fw_ro" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "panel" {
  name                    = "${var.name_prefix}-panel"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "panel" {
  secret_id = aws_secretsmanager_secret.panel.id
  secret_string = jsonencode({
    session_secret = random_password.session.result
    fw_user        = var.fw_readonly_user
    fw_password    = random_password.fw_ro.result
  })
}

# --- Security groups --------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-panel-alb"
  description = "Panel ALB: 443 (and 80 for the HTTPS redirect)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-panel-alb" })

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
    description     = "To panel hosts"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.host.id]
  }
}

resource "aws_security_group" "host" {
  name        = "${var.name_prefix}-panel-host"
  description = "Panel host: 8080 from the ALB only; no SSH (SSM)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-panel-host" })

  egress {
    description = "All outbound (package installs, SSM, LDAP to the DC and API to the firewalls via TGW)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "host_from_alb" {
  type                     = "ingress"
  description              = "Panel web from the ALB"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.host.id
  source_security_group_id = aws_security_group.alb.id
}

# --- IAM (SSM + read own secret; nothing else) -------------------------------
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
  name               = "${var.name_prefix}-panel"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "secret" {
  name = "read-panel-secret"
  role = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.panel.arn
    }]
  })
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.name_prefix}-panel"
  role = aws_iam_role.host.name
  tags = var.tags
}

# --- Hosts: one per AZ -------------------------------------------------------
locals {
  base_dn = join(",", [for p in split(".", var.domain_name) : "DC=${p}"])
  app_files = {
    "app.py"        = file("${path.module}/app/app.py")
    "panel_core.py" = file("${path.module}/app/panel_core.py")
  }
}

resource "aws_instance" "panel" {
  count                  = length(var.host_subnet_ids)
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = var.host_subnet_ids[count.index]
  vpc_security_group_ids = [aws_security_group.host.id]
  iam_instance_profile   = aws_iam_instance_profile.host.name
  key_name               = var.key_name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  root_block_device {
    volume_size = 20
    encrypted   = true
  }

  # No secrets here: the host fetches them from Secrets Manager with its role.
  user_data = templatefile("${path.module}/templates/user-data.sh.tpl", {
    region      = data.aws_region.current.region
    secret_id   = aws_secretsmanager_secret.panel.id
    ldap_host   = var.ldap_host
    domain      = var.domain_name
    netbios     = upper(split(".", var.domain_name)[0])
    base_dn     = local.base_dn
    admin_group = var.admin_group
    fw_ips      = join(",", var.fw_mgmt_ips)
    spoke_host  = var.spoke_host
    app_b64     = base64gzip(local.app_files["app.py"])
    core_b64    = base64gzip(local.app_files["panel_core.py"])
  })
  user_data_replace_on_change = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-panel-${count.index + 1}" })

  depends_on = [aws_secretsmanager_secret_version.panel]
}

# --- ALB --------------------------------------------------------------------
resource "aws_lb" "this" {
  name                       = "${var.name_prefix}-panel"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.alb_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  tags                       = var.tags
}

resource "aws_lb_target_group" "this" {
  name     = "${var.name_prefix}-panel"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  stickiness {
    type    = "lb_cookie"
    enabled = true
  }
  tags = var.tags
}

resource "aws_lb_target_group_attachment" "this" {
  count            = length(aws_instance.panel)
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = aws_instance.panel[count.index].id
  port             = 8080
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
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
