# module: cloudfront

Purpose: CDN in front of the inbound app (Apache/WordPress).

AWS resources: `aws_cloudfront_distribution` (origin = NLB DNS / app public
endpoint), `aws_cloudfront_origin_access_control` if needed, optional
`aws_wafv2_web_acl` + association, and an ACM cert (in us-east-1 for CloudFront).

Load-bearing:
- CloudFront ACM certs must be in **us-east-1** regardless of app region.
- Origin points at the app inbound (NLB), not at firewall management.
- HTTPS redirect + no-cache defaults.
