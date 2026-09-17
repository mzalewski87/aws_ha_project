###############################################################################
# modules/spoke1_app — main
#
# Ubuntu 22.04 + Apache2. Kept on Ubuntu (apt/apache2) for parity with the Azure
# spoke1_app so the infinite-retry installer ports verbatim.
#
# KNOWN RACE (ported from Azure): this host is created in Phase 1b, but its
# outbound apt path depends on the FW security policy/NAT pushed in Phase 2b.
# cloud-init's `packages:` fails-fast, so apache2 is installed by a systemd
# unit that retries every 60s INDEFINITELY until apt succeeds — surviving any
# delay in the upstream FW config push.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-spoke1-app"
  description = "Apache app - HTTP/HTTPS from the internal supernet (via FW)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-spoke1-app" })

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_client_cidrs
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_client_cidrs
  }
  egress {
    description = "All outbound (via TGW to FW)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

###############################################################################
# SSM access for the app host
#
# WHY: docs/DEPLOYMENT.md's troubleshooting tells you to read
# /var/log/cloud-init-apache.log when Apache does not come up — but there was no
# way to reach this host at all. It sits in a spoke behind the firewall with no
# public IP, no key-based path from the jump host, and (unlike the domain
# controller) no SSM agent. Live-hit 2026-09-15: the instance was recreated, the
# page stopped serving, and the documented diagnostic was unreachable.
#
# Ubuntu 22.04's AMI ships the SSM agent preinstalled, so an instance profile is
# all that is needed. Egress to the SSM endpoints goes out through the firewall
# like any other spoke traffic.
###############################################################################

data "aws_iam_policy_document" "app_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.name_prefix}-spoke1-app"
  assume_role_policy = data.aws_iam_policy_document.app_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-spoke1-app" })
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name_prefix}-spoke1-app"
  role = aws_iam_role.app.name
  tags = merge(var.tags, { Name = "${var.name_prefix}-spoke1-app" })
}

resource "aws_instance" "apache" {
  # data.aws_ami.ubuntu is a `most_recent` lookup, so a newly published Ubuntu
  # AMI makes `ami` drift and forces REPLACEMENT on an unrelated apply. This app
  # host is disposable (user-data reinstalls Apache), so the blast radius is
  # small — but the churn is still surprising and it takes the demo page down
  # mid-deploy. Recycle it deliberately with `-replace=` when you want a new AMI.
  lifecycle {
    ignore_changes = [ami]
  }

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  private_ip             = var.private_ip
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name
  key_name               = var.key_name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = base64encode(<<-CLOUDINIT
#cloud-config
# Do NOT use the standard `packages:` directive — see the Phase 1b/2b race note
# in main.tf. apache2 is installed by apache2-bootstrap.service (retries 60s).

write_files:
  - path: /var/www/html/index.html
    owner: www-data:www-data
    permissions: '0644'
    content: |
      <!DOCTYPE html>
      <html lang="en">
      <head><meta charset="UTF-8"><title>AWS VM-Series HA + GlobalProtect Demo</title>
      <style>
        body { font-family: Arial, sans-serif; margin: 0; background: #f5f5f5; }
        .header { background: #0c3b6e; color: white; padding: 20px 40px; }
        .content { padding: 40px; max-width: 800px; margin: auto; }
        .badge { display: inline-block; background: #e31837; color: white;
                 padding: 4px 12px; border-radius: 4px; font-size: 12px; }
        .info-box { background: white; border-left: 4px solid #0c3b6e; padding: 20px;
                    margin: 20px 0; border-radius: 4px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
      </style></head>
      <body>
        <div class="header"><h1>AWS VM-Series HA + GlobalProtect Demo</h1></div>
        <div class="content">
          <span class="badge">HELLO WORLD</span>
          <h2>Apache2 — Spoke1</h2>
          <div class="info-box"><h3>Traffic Path</h3>
            <p>Client &rarr; CloudFront &rarr; App NLB &rarr; VM-Series (inspect + DNAT)
               &rarr; this host (${var.private_ip}, Spoke1 VPC)</p></div>
          <div class="info-box"><h3>Architecture</h3><ul>
            <li>Firewall: <code>2x VM-Series Active/Passive HA</code></li>
            <li>Hub: <code>Transit Gateway (appliance mode)</code></li>
            <li>Managed by: <code>Panorama</code></li>
          </ul></div>
          <p><em>All traffic to this server is inspected by Palo Alto Networks VM-Series.</em></p>
        </div>
      </body></html>

  - path: /usr/local/sbin/install-apache.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Install apache2 with infinite retry. Exits 0 only on success; the systemd
      # unit (Restart=on-failure, RestartSec=60) re-invokes until apt succeeds
      # (typically once the FW dataplane egress is up — Phase 2b).
      LOG=/var/log/cloud-init-apache.log
      echo "[$(date -Is)] install-apache.sh attempt" >> "$LOG"
      if command -v apache2 >/dev/null 2>&1; then
        systemctl enable apache2 >> "$LOG" 2>&1 || true
        systemctl restart apache2 >> "$LOG" 2>&1 || true
        exit 0
      fi
      if apt-get update >> "$LOG" 2>&1 \
         && DEBIAN_FRONTEND=noninteractive apt-get install -y apache2 >> "$LOG" 2>&1; then
        echo "[$(date -Is)] apache2 installed" >> "$LOG"
        systemctl enable apache2 >> "$LOG" 2>&1 || true
        systemctl restart apache2 >> "$LOG" 2>&1 || true
        exit 0
      fi
      echo "[$(date -Is)] install FAILED — systemd retries in 60s" >> "$LOG"
      exit 1

  - path: /etc/systemd/system/apache2-bootstrap.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Install apache2 via apt-get with infinite retry
      After=network-online.target
      Wants=network-online.target
      ConditionPathExists=!/usr/sbin/apache2
      # Without this, five quick failures (e.g. egress not up yet) trip
      # systemd's default start-rate limit and the unit is abandoned for good —
      # exactly the failure this retry loop exists to survive. Belongs in
      # [Unit] on systemd 229+; [Service] only still works for compatibility.
      StartLimitIntervalSec=0

      [Service]
      # NOT Type=oneshot. systemd REFUSES to load a oneshot unit that sets
      # Restart= to anything but "no" ("Service has Restart= setting other than
      # no, which isn't allowed for Type=oneshot services. Refusing."), so the
      # unit never loaded and the advertised infinite retry never ran even once
      # — the install only ever had the single shot cloud-init's runcmd gave it.
      # Type=simple keeps Restart=on-failure legal: the script exits 0 once
      # apache2 is installed and systemd stops retrying; any non-zero exit is
      # retried after RestartSec. ConditionPathExists is re-evaluated on each
      # restart, so it also self-terminates once apache2 exists.
      Type=simple
      ExecStart=/usr/local/sbin/install-apache.sh
      Restart=on-failure
      RestartSec=60s

      [Install]
      WantedBy=multi-user.target

runcmd:
  - systemctl daemon-reload
  - systemctl enable apache2-bootstrap.service
  - systemctl start --no-block apache2-bootstrap.service
CLOUDINIT
  )

  tags = merge(var.tags, { Name = "${var.name_prefix}-spoke1-apache" })
}
