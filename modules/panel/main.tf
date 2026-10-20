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
      Resource = [aws_secretsmanager_secret.panel.arn, aws_secretsmanager_secret.app.arn]
    }]
  })
}

data "aws_caller_identity" "current" {}

# Failover tests: the ONLY EC2 rights of the panel. Describe is not resource-scoped by AWS;
# stop/start are limited to the firewall instances themselves.
resource "aws_iam_role_policy" "topology" {
  count = length(var.fw_map) > 0 ? 1 : 0
  name  = "read-topology-and-runs"
  role  = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read-only; AWS does not scope these Describe calls to resources.
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeAddresses", "ec2:DescribeRouteTables"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Scan"]
        Resource = aws_dynamodb_table.runs.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "failover" {
  count = var.enable_failover ? 1 : 0
  name  = "failover-tests-firewalls-only"
  role  = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ec2:StopInstances", "ec2:StartInstances"]
        Resource = [
          for u in values(var.fw_map) :
          "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/${u.id}"
        ]
      }
    ]
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

  # The application code travels in a second secret, not in user_data: EC2 caps user_data at
  # 16 KB and the Python files alone exceed it. The host fetches it with its instance role.
  # Every .py/.js/.css under app/ except the unit tests, gzipped (a secret holds at most 64 KB).
  app_files = {
    for f in fileset("${path.module}/app", "**") : f => file("${path.module}/app/${f}")
    if !startswith(basename(f), "test_") && length(regexall("\\.(py|js|css)$", f)) > 0
  }
  app_bundle = base64gzip(jsonencode(local.app_files))
}

# Failover runs (progress + history), shared by both hosts.
resource "aws_dynamodb_table" "runs" {
  name         = "${var.name_prefix}-panel-runs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
  point_in_time_recovery {
    enabled = false
  }
  tags = var.tags
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.name_prefix}-panel-app"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = local.app_bundle
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
    # Failover tests (empty map = disabled; the app then hides the controls).
    topo_b64 = base64encode(jsonencode({
      units             = var.fw_map
      eip_allocation_id = var.eip_allocation_id
      public_ip         = var.public_ip
    }))
    failover_enabled = var.enable_failover ? "1" : "0"
    runs_table       = aws_dynamodb_table.runs.name
    operator_group   = var.operator_group
    gp_fqdn          = var.gp_portal_fqdn
    app_secret_id    = aws_secretsmanager_secret.app.id
    app_sha          = sha256(local.app_bundle) # new code => new user_data => the hosts are replaced
  })
  user_data_replace_on_change = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-panel-${count.index + 1}" })

  depends_on = [aws_secretsmanager_secret_version.panel, aws_secretsmanager_secret_version.app]
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
