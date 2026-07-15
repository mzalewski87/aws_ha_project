###############################################################################
# modules/panorama — main
#
# Panorama (EC2 BYOL) with no public IP + a dedicated log EBS volume, plus an
# SSM-managed jump host that provides the management-plane tunnel to Panorama
# (ADR D8). Ports the Azure `panorama` module; the Azure accelerated-networking
# hazard has no AWS analog and is dropped. IMDSv2 required on all instances.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

data "aws_subnet" "panorama" {
  id = var.panorama_subnet_id
}

# Panorama BYOL AMI (Marketplace). Requires a one-time per-account subscription
# (console-only; no CLI accept-terms analog to `az vm image terms accept`).
data "aws_ami" "panorama" {
  count       = var.panorama_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "product-code"
    values = [var.panorama_product_code]
  }
  filter {
    name   = "name"
    values = ["Panorama-AWS-${var.panorama_version}*"]
  }
}

# Amazon Linux 2023 AMI for the SSM jump host (always latest via public SSM param).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_region" "current" {}

###############################################################################
# Security groups
###############################################################################
resource "aws_security_group" "panorama" {
  name        = "${var.name_prefix}-panorama"
  description = "Panorama mgmt (SSH/HTTPS) + PAN-OS control plane from mgmt/security"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-panorama" })

  ingress {
    description = "SSH from mgmt/security"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_mgmt_cidrs
  }
  ingress {
    description = "HTTPS (GUI + panos provider via SSM tunnel jump host)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_mgmt_cidrs
  }
  ingress {
    description = "PAN-OS device to/from Panorama control plane"
    from_port   = 3978
    to_port     = 3978
    protocol    = "tcp"
    cidr_blocks = var.allowed_mgmt_cidrs
  }
  ingress {
    description = "PAN-OS HA / log collector"
    from_port   = 28443
    to_port     = 28443
    protocol    = "tcp"
    cidr_blocks = var.allowed_mgmt_cidrs
  }
  egress {
    description = "All outbound (licensing, updates, collectors)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "jumphost" {
  name        = "${var.name_prefix}-ssm-jumphost"
  description = "SSM jump host - no inbound; egress all (SSM + tunnel to Panorama)"
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

###############################################################################
# SSM jump host IAM (Panorama itself cannot run the SSM agent)
###############################################################################
data "aws_iam_policy_document" "jumphost_assume" {
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
  assume_role_policy = data.aws_iam_policy_document.jumphost_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-ssm-jumphost" })
}

resource "aws_iam_role_policy_attachment" "jumphost_ssm" {
  role       = aws_iam_role.jumphost.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jumphost" {
  name = "${var.name_prefix}-ssm-jumphost"
  role = aws_iam_role.jumphost.name
  tags = merge(var.tags, { Name = "${var.name_prefix}-ssm-jumphost" })
}

###############################################################################
# Panorama instance
###############################################################################
resource "aws_network_interface" "panorama" {
  subnet_id       = var.panorama_subnet_id
  private_ips     = [var.panorama_private_ip]
  security_groups = [aws_security_group.panorama.id]
  tags            = merge(var.tags, { Name = "${var.name_prefix}-panorama-mgmt" })
}

resource "aws_instance" "panorama" {
  ami           = coalesce(var.panorama_ami_id, try(data.aws_ami.panorama[0].id, null))
  instance_type = var.panorama_instance_type
  key_name      = var.key_name

  network_interface {
    network_interface_id = aws_network_interface.panorama.id
    device_index         = 0
  }

  root_block_device {
    volume_size = var.root_disk_size_gb
    volume_type = "gp3"
    encrypted   = true
    tags        = merge(var.tags, { Name = "${var.name_prefix}-panorama-root" })
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 required
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-panorama" })
}

resource "aws_ebs_volume" "panorama_logs" {
  availability_zone = data.aws_subnet.panorama.availability_zone
  size              = var.log_disk_size_gb
  type              = var.log_disk_type
  encrypted         = true
  tags              = merge(var.tags, { Name = "${var.name_prefix}-panorama-logs" })
}

resource "aws_volume_attachment" "panorama_logs" {
  device_name = "/dev/sdb"
  volume_id   = aws_ebs_volume.panorama_logs.id
  instance_id = aws_instance.panorama.id
}

###############################################################################
# SSM jump host
###############################################################################
resource "aws_instance" "jumphost" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.jumphost_instance_type
  subnet_id              = var.ssm_subnet_id
  vpc_security_group_ids = [aws_security_group.jumphost.id]
  iam_instance_profile   = aws_iam_instance_profile.jumphost.name
  key_name               = var.key_name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-ssm-jumphost" })
}

###############################################################################
# First-boot admin password (Azure parity).
#
# PAN-OS on AWS has no platform admin-password injection (EC2 has no password
# field; Panorama on AWS has no bootstrap). PANW's documented procedure is to
# SSH in with the EC2 key and set the password. We automate exactly that over
# the SSM tunnel, so `terraform apply` is hands-off. Re-runs if the instance or
# the password changes. See scripts/set-panorama-password.sh.
###############################################################################
resource "terraform_data" "set_admin_password" {
  count = var.admin_password == "" ? 0 : 1

  triggers_replace = {
    instance = aws_instance.panorama.id
    password = sha256(var.admin_password)
  }

  depends_on = [aws_volume_attachment.panorama_logs, aws_instance.jumphost]

  provisioner "local-exec" {
    command = "${path.root}/scripts/set-panorama-password.sh"
    environment = {
      AWS_REGION    = data.aws_region.current.region
      JUMP          = aws_instance.jumphost.id
      PANO_IP       = var.panorama_private_ip
      KEY_FILE      = coalesce(var.ssh_private_key_file, pathexpand("~/.ssh/${var.key_name}.pem"))
      PANO_USER     = var.admin_username
      PANO_PASSWORD = var.admin_password
    }
  }
}
