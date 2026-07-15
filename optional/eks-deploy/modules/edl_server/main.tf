###############################################################################
# optional/eks-deploy/modules/edl_server
#
# Ubuntu + nginx EDL server in the MGMT VPC (not the workload spoke — FWs pull
# EDLs over the mgmt path; in-spoke would be self-referential). Serves an EKS
# egress FQDN + IP EDL that the FW security policy references BEFORE the generic
# allow-outbound rule, so EKS nodes can only egress to sanctioned endpoints.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_security_group" "edl" {
  name        = "${var.name_prefix}-eks-edl"
  description = "EKS EDL server - HTTP from FW mgmt path only"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-eks-edl" })

  ingress {
    description = "HTTP EDL pull from the FW mgmt / security CIDR"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }
  egress {
    description = "All outbound (fetch AWS ip-ranges, apt)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

locals {
  nginx_conf = replace(file("${path.module}/files/nginx-edl.conf"), "$${MGMT_CIDR}", var.mgmt_cidr)

  cloud_config = <<-CLOUDINIT
    #cloud-config
    write_files:
      - path: /opt/eks-edl/fqdn_base_list.txt
        encoding: b64
        content: ${base64encode(file("${path.module}/files/fqdn_base_list.txt"))}
      - path: /opt/eks-edl/generate_eks_edl.py
        permissions: '0755'
        encoding: b64
        content: ${base64encode(file("${path.module}/files/generate_eks_edl.py"))}
      - path: /opt/eks-edl/settings.json
        content: '{"region": "${var.region}"}'
      - path: /etc/nginx/sites-available/edl.conf
        encoding: b64
        content: ${base64encode(local.nginx_conf)}
      - path: /etc/systemd/system/eks-edl-update.service
        encoding: b64
        content: ${base64encode(file("${path.module}/files/eks-edl-update.service"))}
      - path: /etc/systemd/system/eks-edl-update.timer
        encoding: b64
        content: ${base64encode(file("${path.module}/files/eks-edl-update.timer"))}
    runcmd:
      - export DEBIAN_FRONTEND=noninteractive
      - apt-get update && apt-get install -y nginx python3
      - rm -f /etc/nginx/sites-enabled/default
      - ln -sf /etc/nginx/sites-available/edl.conf /etc/nginx/sites-enabled/edl.conf
      - mkdir -p /var/www/html/edl
      - systemctl restart nginx
      - systemctl daemon-reload
      - systemctl enable --now eks-edl-update.timer
      - systemctl start eks-edl-update.service
  CLOUDINIT
}

resource "aws_instance" "edl" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  private_ip             = var.private_ip
  vpc_security_group_ids = [aws_security_group.edl.id]
  key_name               = var.key_name
  user_data              = base64encode(local.cloud_config)

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tags = merge(var.tags, { Name = "${var.name_prefix}-eks-edl" })
}
