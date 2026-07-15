###############################################################################
# optional/eks-deploy — providers
#
# Separate workspace (own state). Consumes the existing TGW + MGMT VPC from the
# root stack via variables (terraform output). kubernetes/helm target the EKS
# cluster this workspace creates.
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.53" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.15" }
  }
}

provider "aws" {
  region = var.region
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks_cluster.cluster_name
}

provider "kubernetes" {
  host                   = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_cluster.cluster_ca)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks_cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_cluster.cluster_ca)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
