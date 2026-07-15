###############################################################################
# optional/eks-deploy/modules/cloudfront_wordpress
#
# CloudFront in front of the WordPress Kubernetes LoadBalancer. Origin domain is
# the LB hostname (known only after the Helm release provisions the service — pass
# it in via var). HTTP to origin (the sample chart has no TLS), HTTPS to viewers.
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

resource "aws_cloudfront_distribution" "wordpress" {
  enabled         = true
  comment         = "${var.name_prefix} — WordPress on EKS"
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true
  tags            = merge(var.tags, { Name = "${var.name_prefix}-wordpress-cdn" })

  origin {
    origin_id   = "wordpress-lb"
    domain_name = var.origin_domain_name
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "wordpress-lb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = true
      headers      = ["Host"]
      cookies { forward = "all" }
    }
    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
