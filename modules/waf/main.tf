###############################################################################
# modules/waf — AWS WAF (v2) web ACL for a public endpoint
#
# One ACL per endpoint: scope REGIONAL for an ALB (same region), CLOUDFRONT for a distribution
# (the caller passes the us-east-1 provider). Rules, in evaluation order:
#   0 geo-allow     block every request whose source country is not in allowed_countries
#   1 rate-limit    block an IP above rate_limit requests per 5 minutes
#   2..6 AWS managed rule groups: IP reputation, anonymous IPs (VPN/Tor/hosting), known bad
#     inputs (Log4j and friends), the core rule set (OWASP-style), SQL injection
# Default action: allow. Every rule emits CloudWatch metrics and sampled requests.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

locals {
  managed = [
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 2 },
    { name = "AWSManagedRulesAnonymousIpList", priority = 3 },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 4 },
    { name = "AWSManagedRulesCommonRuleSet", priority = 5 },
    { name = "AWSManagedRulesSQLiRuleSet", priority = 6 },
  ]
  metric = replace(var.name, "/[^A-Za-z0-9]/", "")
}

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = var.description
  scope       = var.scope

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = length(var.allowed_countries) > 0 ? [1] : []
    content {
      name     = "geo-allow-only"
      priority = 0
      action {
        block {}
      }
      statement {
        not_statement {
          statement {
            geo_match_statement {
              country_codes = var.allowed_countries
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.metric}GeoBlock"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.metric}RateLimit"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = { for m in local.managed : m.name => m }
    content {
      name     = rule.key
      priority = rule.value.priority
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.metric}${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.metric
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# REGIONAL ACLs are attached here (ALB); a CLOUDFRONT ACL is attached by the distribution
# itself (web_acl_id), so it takes no association resource.
# count, not for_each over the ARNs: on a fresh deployment the ALB ARN is only known after
# apply, and for_each keys must be known at plan time.
resource "aws_wafv2_web_acl_association" "this" {
  count        = var.scope == "REGIONAL" ? length(var.resource_arns) : 0
  resource_arn = var.resource_arns[count.index]
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}
