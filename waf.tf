###############################################################################
# AWS WAF in front of the two public web endpoints (path B lab):
#   * the admin panel ALB           -> REGIONAL web ACL (Region A)
#   * the test website (CloudFront) -> CLOUDFRONT web ACL (us-east-1)
# GlobalProtect (portal/gateways via Global Accelerator / EIPs) is NOT behind WAF: WAF only
# fronts HTTP(S) on ALB / CloudFront / API Gateway, and GP must reach the firewalls directly.
# Rules: geo allow-list (waf_allowed_countries), per-IP rate limit, AWS managed rule groups
# (IP reputation, anonymous IPs, known bad inputs, core rule set, SQLi) — see modules/waf.
###############################################################################

locals {
  web_waf_on   = var.enable_waf && local.web_domain_on
  panel_waf_on = var.enable_waf && local.panel_on
}

module "panel_waf" {
  count  = local.panel_waf_on ? 1 : 0
  source = "./modules/waf"

  name              = "${var.name_prefix}-panel"
  description       = "Admin panel ALB"
  scope             = "REGIONAL"
  allowed_countries = var.waf_allowed_countries
  rate_limit        = var.waf_panel_rate_limit
  resource_arns     = [module.region_a.panel_alb_arn]
  tags              = var.common_tags
}

module "website_waf" {
  count     = local.web_waf_on ? 1 : 0
  source    = "./modules/waf"
  providers = { aws = aws.us_east_1 }

  name              = "${var.name_prefix}-website"
  description       = "Test website on CloudFront"
  scope             = "CLOUDFRONT"
  allowed_countries = var.waf_allowed_countries
  rate_limit        = var.waf_website_rate_limit
  tags              = var.common_tags
}
