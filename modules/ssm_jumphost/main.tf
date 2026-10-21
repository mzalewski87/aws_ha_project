###############################################################################
# modules/ssm_jumphost — standalone SSM jump host (management_mode = "scm")
#
# In Panorama mode the jump host lives inside modules/panorama (PAN-OS has no
# SSM agent, so something in the VPC must tunnel to it). With Strata Cloud
# Manager there is no Panorama, but the jump host is still needed: it is the
# SSM port-forward / SSH hop to the firewalls' mgmt interfaces for the
# device-local steps SCM cannot do (GlobalProtect portal/gateway via XML API,
# PAN-OS HA verification). No inbound rules; access is SSM-only.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "jumphost" {
  name        = "${var.name_prefix}-ssm-jumphost"
  description = "SSM jump host - no inbound; egress all (SSM + tunnel to firewalls)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-ssm-jumphost" })

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jumphost" {
  name               = "${var.name_prefix}-ssm-jumphost"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-ssm-jumphost" })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jumphost.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jumphost" {
  name = "${var.name_prefix}-ssm-jumphost"
  role = aws_iam_role.jumphost.name
  tags = merge(var.tags, { Name = "${var.name_prefix}-ssm-jumphost" })
}

resource "aws_instance" "jumphost" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.jumphost.id]
  iam_instance_profile   = aws_iam_instance_profile.jumphost.name
  key_name               = var.key_name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-ssm-jumphost" })

  # Always-latest AMI parameter: a new AL2023 release must not replace the jump host.
  lifecycle {
    ignore_changes = [ami]
  }
}
