###############################################################################
# modules/panorama_config — EKS egress External Dynamic Lists (optional)
#
# Ports the Azure panorama_aks_rules concept: the EDL server (optional/eks-deploy)
# serves an FQDN + IP list of sanctioned EKS-egress endpoints; these EDLs are
# referenced by an egress-allow rule placed BEFORE the generic spokes-outbound
# rule (see main.tf local.edl_rules) so EKS nodes can ONLY reach approved
# destinations. Gated by var.enable_edl.
###############################################################################

resource "panos_external_dynamic_list" "eks_fqdn" {
  count    = var.enable_edl ? 1 : 0
  location = local.dg_loc
  name     = "eks-egress-fqdn"

  type = {
    domain = {
      url         = "http://${var.edl_server_ip}/edl/eks-egress-fqdn.txt"
      description = "Sanctioned EKS egress FQDNs"
      recurring   = { hourly = {} }
    }
  }
}

resource "panos_external_dynamic_list" "eks_ip" {
  count    = var.enable_edl ? 1 : 0
  location = local.dg_loc
  name     = "eks-egress-ips"

  type = {
    ip = {
      url         = "http://${var.edl_server_ip}/edl/eks-egress-ips.txt"
      description = "Sanctioned EKS egress IP ranges (AWS)"
      recurring   = { hourly = {} }
    }
  }
}
