output "release_name" { value = helm_release.wordpress.name }
output "namespace" { value = helm_release.wordpress.namespace }
# The LoadBalancer hostname is only known after the service is provisioned:
#   kubectl -n wordpress get svc wordpress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# Feed it to module.cloudfront_wordpress.origin_domain_name.
