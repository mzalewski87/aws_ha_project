###############################################################################
# optional/eks-deploy/modules/wordpress
#
# Bitnami WordPress via Helm. service.type=LoadBalancer provisions an in-cluster
# AWS load balancer; CloudFront (cloudfront_wordpress) fronts it. Image/chart
# pulls must be permitted by the EKS-egress EDL + FW policy first.
###############################################################################

terraform {
  required_providers {
    helm = { source = "hashicorp/helm" }
  }
}

resource "helm_release" "wordpress" {
  name             = "wordpress"
  namespace        = var.namespace
  create_namespace = true
  repository       = "https://charts.bitnami.com/bitnami"
  chart            = "wordpress"
  version          = var.chart_version

  set {
    name  = "service.type"
    value = "LoadBalancer"
  }
  set {
    name  = "wordpressUsername"
    value = var.wordpress_username
  }
  set_sensitive {
    name  = "wordpressPassword"
    value = var.wordpress_password
  }
  # Bitnami moved public images to the bitnamilegacy repo — pin so pulls resolve.
  set {
    name  = "image.repository"
    value = var.image_repository
  }
}
