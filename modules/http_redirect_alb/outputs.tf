output "alb_arn" {
  description = "ALB ARN — register as the Global Accelerator :80 listener endpoint."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "ALB DNS name (for direct testing of the redirect, bypassing GA)."
  value       = aws_lb.this.dns_name
}
