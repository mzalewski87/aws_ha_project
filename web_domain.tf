###############################################################################
# Custom domain for the Apache app: https://<web_app_hostname>.<subdomain_zone>
#
# WHY CLOUDFRONT AND NOT TLS DECRYPTION ON THE FIREWALL
# -----------------------------------------------------
# PAN-OS SSL Inbound Inspection *inspects* an already-encrypted session — it
# does not terminate TLS on behalf of a plaintext backend. The Spoke1 Apache
# host listens on port 80 only, so there is nothing to inspect; what is needed
# is TLS TERMINATION. CloudFront already fronts this app (CloudFront -> app NLB
# -> firewall DNAT -> Apache), so terminating there adds no new component, keeps
# the inspection path unchanged, and reuses the caching/Shield edge.
#
# WHY AN ACM CERTIFICATE AND NOT THE LET'S ENCRYPT ONE
# -----------------------------------------------------
# The LE wildcard does cover this name and could be imported into ACM, but an
# IMPORTED certificate never auto-renews: every 90 days someone must re-import
# it by hand or the site breaks. An ACM-issued certificate validated through the
# Route53 zone we already control renews itself indefinitely, at no cost. The LE
# certificate stays where ACM cannot help — on the firewalls, for GlobalProtect,
# since PAN-OS cannot consume an ACM ARN.
#
# Requires enable_custom_domain = true (that is what creates the Route53 zone).
###############################################################################

locals {
  web_domain_on = var.enable_custom_domain && var.web_app_hostname != ""
  web_fqdn      = local.web_domain_on ? "${var.web_app_hostname}.${var.custom_domain_subdomain_zone}" : ""
}

# CloudFront accepts viewer certificates ONLY from us-east-1 — hence the aliased
# provider. DNS validation is used because we own the zone; it needs no inbound
# reachability and is what makes automatic renewal possible.
resource "aws_acm_certificate" "web" {
  count             = local.web_domain_on ? 1 : 0
  provider          = aws.us_east_1
  domain_name       = local.web_fqdn
  validation_method = "DNS"
  tags              = merge(var.common_tags, { Name = "${var.name_prefix}-web-cert" })

  # ACM issues a replacement before the old one is detached, avoiding a window
  # where the distribution references a certificate that no longer exists.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "web_cert_validation" {
  for_each = local.web_domain_on ? {
    for o in aws_acm_certificate.web[0].domain_validation_options : o.domain_name => {
      name = o.resource_record_name, type = o.resource_record_type, record = o.resource_record_value
    }
  } : {}

  zone_id         = module.custom_domain[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Blocks until ACM observes the DNS record and issues. Passing THIS resource's
# certificate_arn (rather than the certificate's own) to CloudFront is what
# guarantees the distribution is never updated with an unissued certificate.
resource "aws_acm_certificate_validation" "web" {
  count                   = local.web_domain_on ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.web[0].arn
  validation_record_fqdns = [for r in aws_route53_record.web_cert_validation : r.fqdn]
}

# Alias (not CNAME): an alias record is free, resolves to the distribution's
# current edge addresses, and may coexist at a zone apex if the hostname is ever
# moved there. Z2FDTNDATAQYW2 is CloudFront's fixed hosted-zone ID, but we read
# it from the distribution so it cannot drift.
resource "aws_route53_record" "web_a" {
  count   = local.web_domain_on ? 1 : 0
  zone_id = module.custom_domain[0].zone_id
  name    = local.web_fqdn
  type    = "A"

  alias {
    name                   = module.region_a.app_cloudfront_domain
    zone_id                = module.region_a.app_cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "web_aaaa" {
  count   = local.web_domain_on ? 1 : 0
  zone_id = module.custom_domain[0].zone_id
  name    = local.web_fqdn
  type    = "AAAA"

  alias {
    name                   = module.region_a.app_cloudfront_domain
    zone_id                = module.region_a.app_cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}

output "web_app_url" {
  description = "HTTPS URL of the Apache app on the custom domain (empty when disabled)."
  value       = local.web_domain_on ? "https://${local.web_fqdn}" : ""
}
