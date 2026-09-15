###############################################################################
# modules/cloudfront — outputs
###############################################################################

output "distribution_domain_name" {
  description = "CloudFront distribution domain name (*.cloudfront.net)."
  value       = aws_cloudfront_distribution.app.domain_name
}

output "distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.app.id
}

output "distribution_arn" {
  description = "CloudFront distribution ARN."
  value       = aws_cloudfront_distribution.app.arn
}

output "distribution_hosted_zone_id" {
  description = "Route53 hosted-zone ID of the CloudFront distribution, for alias records."
  value       = aws_cloudfront_distribution.app.hosted_zone_id
}
