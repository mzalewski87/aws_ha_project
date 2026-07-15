###############################################################################
# modules/spoke2_dc — main
#
# Windows Server 2022; when promote_to_dc = true, user-data installs AD DS and
# promotes a new forest, then configures a DNS forwarder so the box can still
# resolve public names post-promotion (see the dc_promote_script comment — a
# fresh AD DNS zone has no forwarders by default, which silently blocks the
# SSM Agent, Windows Update, etc.). The reboot is handed to EC2Launch v2's own
# `exit 3010` mechanism (NOT Install-ADDSForest's built-in restart, which AWS's
# EC2Launch v2 docs warn is "inconsistent" and may not properly re-invoke
# user-data) with <persist>true</persist> kept as a fallback. Idempotency is
# checked via a real Get-ADDomain probe, not just a marker file — re-running
# Install-ADDSForest is safe if a previous attempt didn't finish. Outbound
# (Windows Update / AD prep / SSM) traverses the FW dataplane, so like
# spoke1_app this depends on the Phase 2b policy push being in place.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

locals {
  # Rebooting via any mechanism OTHER than `exit 3010` (e.g. Install-ADDSForest's
  # own built-in restart) makes EC2Launch v2's re-invocation of this script
  # "inconsistent... may not perform the restart" per AWS's own EC2Launch v2
  # docs. -NoRebootOnCompletion + our own `exit 3010` hands the reboot to
  # EC2Launch v2's native, documented reboot-and-re-run-this-script mechanism
  # instead; <persist>true</persist> is kept as a second-chance fallback.
  #
  # Idempotency is checked via a real Get-ADDomain probe, not a marker file — a
  # marker only proves Install-ADDSForest was *invoked*, not that it *finished*,
  # and re-invoking it on a partially-promoted box is safe, whereas silently
  # doing nothing forever on a stuck box (what a marker-only check risks) is not.
  #
  # WHY the DNS forwarder step exists: -InstallDns makes this box authoritative
  # for its own AD DNS zone and re-points its own DNS client at itself. A
  # freshly created AD-integrated DNS zone has NO forwarders configured, so it
  # cannot resolve public names (e.g. ssm.<region>.amazonaws.com) — the SSM
  # Agent then never even attempts a connection (no firewall traffic-log
  # entries from the DC, i.e. packets never leave the host at all).
  # Fix: forward to the VPC's own resolver (base of the VPC CIDR + 2), already
  # reachable via the existing TGW route.
  dc_promote_script = <<-POWERSHELL
    <powershell>
    $promoted = $false
    try {
      Import-Module ActiveDirectory -ErrorAction Stop
      $null = Get-ADDomain -ErrorAction Stop
      $promoted = $true
    } catch { $promoted = $false }

    if (-not $promoted) {
      Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
      $securePwd = ConvertTo-SecureString '${var.safe_mode_password}' -AsPlainText -Force
      Import-Module ADDSDeployment
      Install-ADDSForest `
        -DomainName '${var.domain_name}' `
        -SafeModeAdministratorPassword $securePwd `
        -InstallDns `
        -NoRebootOnCompletion:$true `
        -Force
      exit 3010
    } else {
      $dnsSvc = Get-Service DNS -ErrorAction SilentlyContinue
      if ($dnsSvc -and $dnsSvc.Status -eq 'Running') {
        $resolver = [System.Net.IPAddress]'${var.dns_resolver_ip}'
        $existing = (Get-DnsServerForwarder -ErrorAction SilentlyContinue).IPAddress
        if (-not $existing -or ($existing -notcontains $resolver)) {
          Add-DnsServerForwarder -IPAddress $resolver -PassThru
        }
      }
    }
    </powershell>
    <persist>true</persist>
  POWERSHELL

  # ADDITIONAL domain controller (Region B): join the EXISTING panw.labs forest
  # and promote as a replica of the primary DC, instead of creating a new forest.
  # Same reboot/idempotency discipline as the forest script:
  #  - DNS client is pointed at the primary DC FIRST so the box can resolve the
  #    domain's SRV records (a box that can't find the domain can't be promoted).
  #  - Idempotency via Win32_ComputerSystem.DomainRole (>=4 means it's already a
  #    DC), not a marker file.
  #  - Install-ADDSDomainController does the domain-join + promotion in one step
  #    given a Domain Admin credential; -NoRebootOnCompletion + `exit 3010` hands
  #    the reboot to EC2Launch v2 (see the forest note above).
  #  - Cross-region reachability to primary_dc_ip must be up before this runs.
  dc_additional_script = <<-POWERSHELL
    <powershell>
    $primaryDns = '${var.primary_dc_ip}'
    $ifIndex = (Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).ifIndex
    if ($ifIndex) { Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $primaryDns }

    $isDC = $false
    try { if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) { $isDC = $true } } catch { $isDC = $false }

    if (-not $isDC) {
      Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
      $securePwd = ConvertTo-SecureString '${var.safe_mode_password}' -AsPlainText -Force
      $adminPwd  = ConvertTo-SecureString '${var.domain_admin_password}' -AsPlainText -Force
      $cred      = New-Object System.Management.Automation.PSCredential('${var.domain_admin_user}', $adminPwd)
      Import-Module ADDSDeployment
      Install-ADDSDomainController `
        -DomainName '${var.domain_name}' `
        -Credential $cred `
        -SafeModeAdministratorPassword $securePwd `
        -InstallDns `
        -NoRebootOnCompletion:$true `
        -Force
      exit 3010
    } else {
      $dnsSvc = Get-Service DNS -ErrorAction SilentlyContinue
      if ($dnsSvc -and $dnsSvc.Status -eq 'Running') {
        $resolver = [System.Net.IPAddress]'${var.dns_resolver_ip}'
        $existing = (Get-DnsServerForwarder -ErrorAction SilentlyContinue).IPAddress
        if (-not $existing -or ($existing -notcontains $resolver)) {
          Add-DnsServerForwarder -IPAddress $resolver -PassThru
        }
        # Point the DNS CLIENT at THIS DC (self) first — critical for region-
        # outage resilience: the additional-DC's user-data initially set DNS to
        # the primary DC (10.13) so it could find the domain to promote, but if
        # that stays, a primary-region outage takes DNS down on the SURVIVING DC
        # too, degrading its AD/LDAP and defeating the whole point of a 2nd DC.
        # Self-first (with the primary as secondary) keeps this DC resolving on
        # its own when the other region is gone. Without self-first DNS, Region B
        # GP AD login does not survive a Region A DC outage.
        $self = '${var.private_ip}'
        $if = (Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).ifIndex
        if ($if) { Set-DnsClientServerAddress -InterfaceIndex $if -ServerAddresses @($self, '${var.primary_dc_ip}') }
      }
    }
    </powershell>
    <persist>true</persist>
  POWERSHELL
}

###############################################################################
# SSM access — the DC has no Bastion/jump-host path (spoke2 is behind the FW
# inspection path with no route back to the mgmt VPC). Windows Server 2022's
# AWS AMI ships with the SSM Agent preinstalled, so an instance profile is all
# that's needed: RDP via `aws ssm start-session
# --document-name AWS-StartPortForwardingSession` and day-2 automation via SSM
# RunCommand (both use AmazonSSMManagedInstanceCore). No FW policy or TGW route
# change needed — the SSM control channel is outbound only, already covered by
# the existing spokes-outbound security policy rule.
###############################################################################
data "aws_iam_policy_document" "dc_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dc" {
  name               = "${var.name_prefix}-spoke2-dc"
  assume_role_policy = data.aws_iam_policy_document.dc_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-spoke2-dc" })
}

resource "aws_iam_role_policy_attachment" "dc_ssm" {
  role       = aws_iam_role.dc.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "dc" {
  name = "${var.name_prefix}-spoke2-dc"
  role = aws_iam_role.dc.name
  tags = merge(var.tags, { Name = "${var.name_prefix}-spoke2-dc" })
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

resource "aws_security_group" "dc" {
  name        = "${var.name_prefix}-spoke2-dc"
  description = "Windows DC - RDP from mgmt; AD/DNS/Kerberos/LDAP from internal"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-spoke2-dc" })

  ingress {
    description = "RDP"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = var.allowed_mgmt_cidrs
  }
  # AD DS / DC-to-DC replication needs the full port set, not just 88-445: DRS
  # replication (used during additional-DC promotion AND ongoing sync) rides
  # DYNAMIC RPC high ports (49152-65535), plus GC (3268-3269), kpasswd (464),
  # NTP (123), and UDP variants of Kerberos/LDAP. Enumerating every port is
  # error-prone (a single missing high port silently breaks promotion — the
  # second DC stays unpromoted, 389 closed, SSM offline). These
  # are internal, FW-gated DCs, so allow all TCP+UDP+ICMP from the internal
  # supernet between them.
  ingress {
    description = "All AD DS + DC replication (TCP) from internal"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = var.allowed_internal_cidrs
  }
  ingress {
    description = "All AD DS + DC replication (UDP) from internal"
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = var.allowed_internal_cidrs
  }
  ingress {
    description = "ICMP from internal (ping / PMTU / AD health)"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = var.allowed_internal_cidrs
  }
  egress {
    description = "All outbound (via TGW to FW)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "dc" {
  ami                    = data.aws_ami.windows.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  private_ip             = var.private_ip
  vpc_security_group_ids = [aws_security_group.dc.id]
  key_name               = var.key_name
  get_password_data      = var.key_name != null
  iam_instance_profile   = aws_iam_instance_profile.dc.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = var.promote_to_dc ? (var.is_additional_dc ? local.dc_additional_script : local.dc_promote_script) : null

  tags = merge(var.tags, { Name = "${var.name_prefix}-spoke2-dc" })
}

###############################################################################
# AD test user — see scripts/create-ad-test-user.sh for why this can't just be
# appended to the user-data promotion script (the forest doesn't exist yet when
# user-data runs, and Install-ADDSForest's own reboot would interrupt anything
# queued after it in the same script).
###############################################################################
# Only on the PRIMARY DC (new forest). On an additional DC the account already
# exists via replication, so creating it there would be redundant/racy.
resource "terraform_data" "ad_test_user" {
  count = var.promote_to_dc && !var.is_additional_dc && var.ad_test_user_password != "" ? 1 : 0

  triggers_replace = {
    instance = aws_instance.dc.id
    password = sha256(var.ad_test_user_password)
  }

  provisioner "local-exec" {
    command = "${path.root}/scripts/create-ad-test-user.sh"
    environment = {
      DC_INSTANCE_ID   = aws_instance.dc.id
      AD_USERNAME      = var.ad_test_user_name
      AD_USER_PASSWORD = var.ad_test_user_password
      AD_DOMAIN        = var.domain_name
    }
  }
}
