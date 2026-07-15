###############################################################################
# modules/custom_domain — main
#
# Route53 delegated-subdomain zone + GP portal/gateway records, and an optional
# Let's Encrypt wildcard cert issued by DNS-01 against that same zone.
#
# Provider note: this module uses the default aws provider (Route53 is global,
# but the API is reached through any region) plus acme + tls, all passed in by
# the root module. The acme provider must be configured at the root.
###############################################################################

terraform {
  required_providers {
    aws  = { source = "hashicorp/aws" }
    acme = { source = "vancluever/acme" }
    tls  = { source = "hashicorp/tls" }
  }
}

locals {
  on          = var.enable
  le          = var.enable && var.cert_mode == "letsencrypt"
  portal_fqdn = var.enable ? "${var.portal_hostname}.${var.subdomain_zone}" : ""
  wildcard    = "*.${var.subdomain_zone}"
}

# --- Route53 delegated subdomain zone ---------------------------------------
resource "aws_route53_zone" "sub" {
  count = local.on ? 1 : 0
  name  = var.subdomain_zone
  tags  = merge(var.tags, { Name = "${var.name_prefix}-${var.subdomain_zone}" })
}

# Portal record -> Global Accelerator anycast IPs (or a single portal EIP).
resource "aws_route53_record" "portal" {
  count   = local.on && length(var.portal_target_ips) > 0 ? 1 : 0
  zone_id = aws_route53_zone.sub[0].zone_id
  name    = local.portal_fqdn
  type    = "A"
  ttl     = var.record_ttl
  records = var.portal_target_ips
}

# Per-region gateway records -> that region's firewall EIP.
resource "aws_route53_record" "gateway" {
  for_each = local.on ? var.gateway_records : {}
  zone_id  = aws_route53_zone.sub[0].zone_id
  name     = "${each.key}.${var.subdomain_zone}"
  type     = "A"
  ttl      = var.record_ttl
  records  = [each.value]
}

# --- Let's Encrypt wildcard cert via DNS-01 ---------------------------------
# One wildcard (*.subdomain_zone) covers the portal FQDN and every gateway FQDN,
# so PAN-OS presents a browser-trusted cert on all of them. DNS-01 needs no
# inbound reachability — lego writes the _acme-challenge TXT into the zone above.
resource "tls_private_key" "acme_account" {
  count     = local.le ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "acme_registration" "this" {
  count           = local.le ? 1 : 0
  account_key_pem = tls_private_key.acme_account[0].private_key_pem
  email_address   = var.letsencrypt_email
}

resource "acme_certificate" "wildcard" {
  count                     = local.le ? 1 : 0
  account_key_pem           = acme_registration.this[0].account_key_pem
  common_name               = local.wildcard
  subject_alternative_names = [var.subdomain_zone] # apex too, so gp.<zone> + <zone>

  dns_challenge {
    provider = "route53"
    # lego's route53 provider auth comes from the standard AWS environment /
    # instance role the Terraform process already uses; the hosted zone it must
    # write into is the one created above.
    config = {
      AWS_HOSTED_ZONE_ID = aws_route53_zone.sub[0].zone_id
    }
  }

  depends_on = [aws_route53_zone.sub]
}
