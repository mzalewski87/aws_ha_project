###############################################################################
# Admin panel public hostname: https://<panel_hostname>.<subdomain_zone>
# Same pattern as guacamole.tf: regional ALB, ACM cert DNS-validated in our zone.
###############################################################################

locals {
  panel_on   = var.enable_panel && var.enable_custom_domain
  panel_fqdn = local.panel_on ? "${var.panel_hostname}.${var.custom_domain_subdomain_zone}" : ""
}

resource "terraform_data" "panel_guard" {
  lifecycle {
    precondition {
      condition     = !var.enable_panel || var.enable_custom_domain
      error_message = "enable_panel requires enable_custom_domain = true (the ALB certificate is DNS-validated in the Route53 zone that module custom_domain creates)."
    }
  }
}

resource "aws_acm_certificate" "panel" {
  count             = local.panel_on ? 1 : 0
  domain_name       = local.panel_fqdn
  validation_method = "DNS"
  tags              = merge(var.common_tags, { Name = "${var.name_prefix}-panel-cert" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "panel_cert_validation" {
  for_each = local.panel_on ? {
    for o in aws_acm_certificate.panel[0].domain_validation_options : o.domain_name => {
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

resource "aws_acm_certificate_validation" "panel" {
  count                   = local.panel_on ? 1 : 0
  certificate_arn         = aws_acm_certificate.panel[0].arn
  validation_record_fqdns = [for r in aws_route53_record.panel_cert_validation : r.fqdn]
}

resource "aws_route53_record" "panel_a" {
  count   = local.panel_on ? 1 : 0
  zone_id = module.custom_domain[0].zone_id
  name    = local.panel_fqdn
  type    = "A"

  alias {
    name                   = module.region_a.panel_alb_dns_name
    zone_id                = module.region_a.panel_alb_zone_id
    evaluate_target_health = true
  }
}
