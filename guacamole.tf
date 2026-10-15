###############################################################################
# Guacamole public hostname: https://<guacamole_hostname>.<subdomain_zone>
#
# The ALB is regional (Region A), so unlike the CloudFront cert in web_domain.tf
# the ACM certificate is issued in the DEFAULT provider's region. Same approach:
# DNS validation through the Route53 zone we own, so it renews by itself.
# Requires enable_custom_domain = true (that creates the zone).
###############################################################################

locals {
  guac_on   = var.enable_guacamole && var.enable_custom_domain
  guac_fqdn = local.guac_on ? "${var.guacamole_hostname}.${var.custom_domain_subdomain_zone}" : ""
}

resource "terraform_data" "guacamole_guard" {
  lifecycle {
    precondition {
      condition     = !var.enable_guacamole || var.enable_custom_domain
      error_message = "enable_guacamole requires enable_custom_domain = true (the ALB certificate is DNS-validated in the Route53 zone that module custom_domain creates)."
    }
  }
}

resource "aws_acm_certificate" "guac" {
  count             = local.guac_on ? 1 : 0
  domain_name       = local.guac_fqdn
  validation_method = "DNS"
  tags              = merge(var.common_tags, { Name = "${var.name_prefix}-guacamole-cert" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "guac_cert_validation" {
  for_each = local.guac_on ? {
    for o in aws_acm_certificate.guac[0].domain_validation_options : o.domain_name => {
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

resource "aws_acm_certificate_validation" "guac" {
  count                   = local.guac_on ? 1 : 0
  certificate_arn         = aws_acm_certificate.guac[0].arn
  validation_record_fqdns = [for r in aws_route53_record.guac_cert_validation : r.fqdn]
}

resource "aws_route53_record" "guac_a" {
  count   = local.guac_on ? 1 : 0
  zone_id = module.custom_domain[0].zone_id
  name    = local.guac_fqdn
  type    = "A"

  alias {
    name                   = module.region_a.guacamole_alb_dns_name
    zone_id                = module.region_a.guacamole_alb_zone_id
    evaluate_target_health = true
  }
}
