###############################################################################
# modules/cloudfront — main
#
# Caching effectively disabled (the app/FW handles responses); viewer traffic is
# redirected to HTTPS and terminated on the default *.cloudfront.net cert. Add
# an ACM cert + aliases + WAF when a real FQDN is introduced.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

resource "aws_cloudfront_distribution" "app" {
  enabled         = true
  comment         = "${var.name_prefix} — ${var.comment}"
  price_class     = var.price_class
  is_ipv6_enabled = true
  tags            = merge(var.tags, { Name = "${var.name_prefix}-app-cdn" })

  origin {
    origin_id   = "app-nlb"
    domain_name = var.origin_domain_name

    custom_origin_config {
      http_port              = var.origin_http_port
      https_port             = 443
      origin_protocol_policy = var.origin_protocol_policy
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "app-nlb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
