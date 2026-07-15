###############################################################################
# modules/loadbalancer — outputs
###############################################################################

output "nlb_dns_name" {
  description = "Public DNS name of the app NLB (CloudFront/Route53 origin)."
  value       = aws_lb.app.dns_name
}

output "nlb_arn" {
  description = "ARN of the app NLB."
  value       = aws_lb.app.arn
}

output "nlb_zone_id" {
  description = "Hosted zone ID of the app NLB (for Route 53 alias records)."
  value       = aws_lb.app.zone_id
}
