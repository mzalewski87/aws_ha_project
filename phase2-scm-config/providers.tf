terraform {
  required_version = ">= 1.6"
  required_providers {
    scm = {
      source  = "PaloAltoNetworks/scm"
      version = "~> 1.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# Credentials come from variables (supply via TF_VAR_* or an untracked tfvars) —
# never commit them. The auth API allows ~10 concurrent token requests per
# tenant: apply with -parallelism=4.
provider "scm" {
  client_id     = var.scm_client_id
  client_secret = var.scm_client_secret
  scope         = "tsg_id:${var.scm_tsg_id}"
}
