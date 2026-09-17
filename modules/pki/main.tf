###############################################################################
# modules/pki — two-tier Active Directory Certificate Services
#
# WHY TWO TIERS
# -------------
# The whole point of this PKI is that domain members trust a CA whose signing
# key lives on the firewall (SSL Forward Proxy re-signs every intercepted site).
# That trust anchor must be durable: if the anchor is compromised you cannot
# revoke it — you have to re-distribute trust to every endpoint. So the root is
# standalone, signs exactly one thing (the issuing CA), and is then POWERED OFF.
# Day-to-day issuance happens on the enterprise issuing CA, which is online,
# domain-joined, and disposable: if it is ever compromised the root revokes it
# and signs a replacement, and endpoints never notice.
#
# WHY THE FIREWALL GETS ITS OWN SUBORDINATE CA
# --------------------------------------------
# PAN-OS needs a CA certificate *with its private key* to re-sign traffic. The
# wrong way is to export the issuing CA's key and import it into Panorama — that
# copies the key AD relies on into another system. The right way (what
# scripts/setup-pki.sh does) is to have PAN-OS generate its own key and CSR, and
# have the issuing CA sign it as a subordinate. The firewall's key never leaves
# the firewall, and revoking the firewall's CA does not touch AD's.
#
# Chain: Root CA (offline)  ->  Issuing CA (AD CS, online)  ->  PAN-OS fwd-trust
# Clients trust the Root because AD CS publishes it to the domain's trust store
# automatically; a domain-joined machine picks it up at the next gpupdate.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

###############################################################################
# IAM — SSM only. Every configuration step runs through RunCommand; these hosts
# have no public address and no inbound administrative path.
###############################################################################

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ca" {
  name               = "${var.name_prefix}-pki-ca"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-pki-ca" })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ca.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ca" {
  name = "${var.name_prefix}-pki-ca"
  role = aws_iam_role.ca.name
  tags = merge(var.tags, { Name = "${var.name_prefix}-pki-ca" })
}

###############################################################################
# Security group
###############################################################################

resource "aws_security_group" "ca" {
  name        = "${var.name_prefix}-pki-ca"
  description = "AD CS hosts - AD/RPC from internal, HTTP for AIA/CDP"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-pki-ca" })

  # The issuing CA is a domain member and an RPC server: certificate enrollment
  # (MS-WCCE) rides RPC, which negotiates a high dynamic port after contacting
  # the endpoint mapper on 135. Without the dynamic range, enrollment hangs.
  ingress {
    description = "RPC endpoint mapper"
    from_port   = 135
    to_port     = 135
    protocol    = "tcp"
    cidr_blocks = var.allowed_internal_cidrs
  }
  ingress {
    description = "RPC dynamic range (certificate enrollment)"
    from_port   = 49152
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = var.allowed_internal_cidrs
  }
  ingress {
    description = "SMB (CA cert/CRL file share)"
    from_port   = 445
    to_port     = 445
    protocol    = "tcp"
    cidr_blocks = var.allowed_internal_cidrs
  }
  # AIA and CDP are published over HTTP on purpose: a client validating a chain
  # must fetch them WITHOUT needing a valid chain first, so HTTPS would be
  # circular. The content is public certificates and revocation lists.
  ingress {
    description = "HTTP for AIA + CDP publication"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_internal_cidrs
  }
  ingress {
    description = "ICMP from internal"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = var.allowed_internal_cidrs
  }

  egress {
    description = "All outbound (via TGW to the firewall)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

###############################################################################
# Offline ROOT CA — standalone, deliberately NOT domain-joined
#
# A standalone root has no dependency on AD, which is what lets it be powered
# off and still be authoritative. It is configured once, signs the issuing CA,
# and is then stopped (see scripts/setup-pki.sh, which stops it at the end).
###############################################################################

locals {
  # CRL published far into the future: an offline CA cannot re-issue a CRL on a
  # normal schedule, and an expired CRL fails chain validation everywhere.
  root_userdata = <<-PS1
    <powershell>
    $ErrorActionPreference = "Stop"
    $log = "C:\\ca-bootstrap.log"
    function Log($m) { "$(Get-Date -Format s)  $m" | Out-File -Append $log }

    Log "installing AD CS binaries (standalone root)"
    Install-WindowsFeature AD-Certificate, RSAT-ADCS -IncludeManagementTools | Out-Null

    # Long CRL periods BEFORE configuring the role, so the first CRL inherits them.
    Log "configuring standalone root CA: ${var.ca_common_name_root}"
    Install-AdcsCertificationAuthority `
      -CAType StandaloneRootCA `
      -CACommonName "${var.ca_common_name_root}" `
      -KeyLength 4096 `
      -HashAlgorithmName SHA256 `
      -ValidityPeriod Years -ValidityPeriodUnits ${var.root_ca_validity_years} `
      -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
      -Force | Out-File -Append $log

    # 26 weeks of CRL validity with a 4-week overlap: the root is offline, so a
    # short CRL lifetime would silently break validation the moment it lapsed.
    certutil -setreg CA\\CRLPeriodUnits 26      | Out-File -Append $log
    certutil -setreg CA\\CRLPeriod "Weeks"      | Out-File -Append $log
    certutil -setreg CA\\CRLOverlapUnits 4      | Out-File -Append $log
    certutil -setreg CA\\CRLOverlapPeriod "Weeks" | Out-File -Append $log
    certutil -setreg CA\\CRLDeltaPeriodUnits 0  | Out-File -Append $log
    # Issued certificates (i.e. the issuing CA) get this lifetime cap.
    certutil -setreg CA\\ValidityPeriodUnits ${var.sub_ca_validity_years} | Out-File -Append $log
    certutil -setreg CA\\ValidityPeriod "Years" | Out-File -Append $log

    Restart-Service certsvc
    Start-Sleep -Seconds 10
    certutil -CRL | Out-File -Append $log
    Log "root CA ready"
    </powershell>
    <persist>true</persist>
  PS1

  sub_userdata = <<-PS1
    <powershell>
    $ErrorActionPreference = "Stop"
    $log = "C:\\ca-bootstrap.log"
    function Log($m) { "$(Get-Date -Format s)  $m" | Out-File -Append $log }

    # Point DNS at the domain controller before attempting the join.
    Log "setting DNS to ${var.dns_resolver_ip}"
    Get-NetAdapter | Where-Object Status -eq Up |
      Set-DnsClientServerAddress -ServerAddresses "${var.dns_resolver_ip}"

    $pw   = ConvertTo-SecureString '${var.domain_admin_password}' -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential('${var.domain_admin_user}@${var.domain_name}', $pw)

    # The DC may still be booting; retry rather than fail the whole bootstrap.
    for ($i = 1; $i -le 40; $i++) {
      try {
        Log "domain join attempt $i"
        Add-Computer -DomainName "${var.domain_name}" -Credential $cred -Force -ErrorAction Stop
        Log "joined ${var.domain_name}; rebooting to finish"
        Restart-Computer -Force
        exit 0
      } catch {
        Log "join failed: $($_.Exception.Message)"
        Start-Sleep -Seconds 30
      }
    }
    Log "domain join never succeeded"
    </powershell>
    <persist>true</persist>
  PS1
}

resource "aws_instance" "root_ca" {
  ami                    = data.aws_ami.windows.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  private_ip             = var.root_ca_private_ip
  vpc_security_group_ids = [aws_security_group.ca.id]
  key_name               = var.key_name
  get_password_data      = var.key_name != null
  iam_instance_profile   = aws_iam_instance_profile.ca.name
  user_data              = local.root_userdata

  # Same reasoning as the domain controller: this host holds the trust anchor's
  # private key. A newer Windows AMI must never silently recreate it.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-pki-root-ca", Role = "offline-root-ca" })
}

###############################################################################
# Enterprise ISSUING CA — domain-joined subordinate
###############################################################################

resource "aws_instance" "sub_ca" {
  ami                    = data.aws_ami.windows.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  private_ip             = var.sub_ca_private_ip
  vpc_security_group_ids = [aws_security_group.ca.id]
  key_name               = var.key_name
  get_password_data      = var.key_name != null
  iam_instance_profile   = aws_iam_instance_profile.ca.name
  user_data              = local.sub_userdata

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-pki-sub-ca", Role = "issuing-ca" })
}
