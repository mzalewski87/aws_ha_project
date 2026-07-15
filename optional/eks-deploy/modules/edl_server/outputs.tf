output "private_ip" {
  value       = aws_instance.edl.private_ip
  description = "EDL server IP — build the PAN-OS EDL URLs from this."
}
output "fqdn_edl_url" {
  value = "http://${aws_instance.edl.private_ip}/edl/eks-egress-fqdn.txt"
}
output "ip_edl_url" {
  value = "http://${aws_instance.edl.private_ip}/edl/eks-egress-ips.txt"
}
