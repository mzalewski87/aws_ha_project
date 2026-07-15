###############################################################################
# Terraform & Provider Configuration
# AWS VM-Series HA — Multi-Region GlobalProtect (Transit VPC)
#
# Phase 1 (this directory): aws + random/time/null/local ONLY
# Phase 2 (phase2-panorama-config/): panos provider (kept separate because it
#   connects to Panorama on every `plan`).
#
# Multi-region-ready from day one: provider is aliased per region. Region A is
# the default; Region B is enabled in Phase R2. Do NOT hardcode regions inside
# modules — pass providers/region in from here.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.53" # AWS provider is on major v6.
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    # Custom-domain Let's Encrypt path (modules/custom_domain, off by default).
    # Only exercised when var.custom_domain_cert_mode = "letsencrypt"; harmless
    # otherwise (the provider does nothing until a resource references it).
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.20"
    }
  }

  # Configure an S3 + DynamoDB backend before real applies.
  # backend "s3" {}
}

# Region A (default / primary)
provider "aws" {
  region = var.region_a
  default_tags { tags = var.common_tags }
}

# Region B (Phase R2 — multi-region resilience). Safe to leave configured; no
# resources target it until the R2 phase feature-flags them on.
provider "aws" {
  alias  = "region_b"
  region = var.region_b
  default_tags { tags = var.common_tags }
}

# Global Accelerator control plane lives in us-west-2 — the aws_globalaccelerator_*
# resources must be created against this region regardless of where endpoints are.
provider "aws" {
  alias  = "global"
  region = "us-west-2"
  default_tags { tags = var.common_tags }
}

# ACME (Let's Encrypt) for the optional custom-domain cert (DNS-01 via Route53).
# Staging endpoint avoids the strict prod rate limits while testing; flip
# custom_domain_letsencrypt_staging = false for a browser-trusted cert.
provider "acme" {
  server_url = var.custom_domain_letsencrypt_staging ? "https://acme-staging-v02.api.letsencrypt.org/directory" : "https://acme-v02.api.letsencrypt.org/directory"
}
