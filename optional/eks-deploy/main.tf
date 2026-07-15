###############################################################################
# optional/eks-deploy — EKS + WordPress with FW egress control via a custom EDL.
#
# Order matters: the EDL server + the Panorama EDL rules (phase2 edl.tf) must be
# in place BEFORE the node group starts, or node bootstrap (ECR/registry pulls)
# is denied. Run phase2 with enable_edl=true first, then this workspace.
###############################################################################

data "aws_availability_zones" "this" {
  state = "available"
}

module "eks_network" {
  source             = "./modules/eks_network"
  name_prefix        = var.name_prefix
  vpc_cidr           = var.eks_vpc_cidr
  azs                = slice(data.aws_availability_zones.this.names, 0, 2)
  transit_gateway_id = var.transit_gateway_id
  tags               = var.tags
}

# EDL server in the MGMT VPC (must exist before nodes join).
module "edl_server" {
  source        = "./modules/edl_server"
  name_prefix   = var.name_prefix
  vpc_id        = var.mgmt_vpc_id
  subnet_id     = var.edl_subnet_id
  private_ip    = var.edl_private_ip
  region        = var.region
  mgmt_cidr     = var.security_vpc_cidr
  allowed_cidrs = [var.security_vpc_cidr]
  key_name      = var.key_name
  tags          = var.tags
}

module "eks_cluster" {
  source             = "./modules/eks_cluster"
  name_prefix        = var.name_prefix
  node_subnet_ids    = module.eks_network.node_subnet_ids
  kubernetes_version = var.kubernetes_version
  tags               = var.tags

  # Nodes need the egress path sanctioned first.
  depends_on = [module.edl_server]
}

module "wordpress" {
  source             = "./modules/wordpress"
  wordpress_password = var.wordpress_password
  depends_on         = [module.eks_cluster]
}

# CloudFront in front of the WordPress LB — created once the LB hostname is known.
module "cloudfront_wordpress" {
  count              = var.wordpress_lb_hostname != "" ? 1 : 0
  source             = "./modules/cloudfront_wordpress"
  name_prefix        = var.name_prefix
  origin_domain_name = var.wordpress_lb_hostname
  tags               = var.tags
}
