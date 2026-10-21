output "arn" {
  description = "Web ACL ARN (CloudFront: pass as the distribution's web_acl_id)."
  value       = aws_wafv2_web_acl.this.arn
}
