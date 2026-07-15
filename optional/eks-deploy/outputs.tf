output "cluster_name" { value = module.eks_cluster.cluster_name }
output "eks_vpc_id" { value = module.eks_network.vpc_id }
output "edl_fqdn_url" { value = module.edl_server.fqdn_edl_url }
output "edl_ip_url" { value = module.edl_server.ip_edl_url }
output "wordpress_cloudfront_domain" {
  value = var.wordpress_lb_hostname != "" ? module.cloudfront_wordpress[0].distribution_domain_name : null
}
