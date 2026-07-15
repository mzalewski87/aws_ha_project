# optional/eks-deploy — EKS + WordPress with FW-controlled egress (EDL)

Separate workspace (own state). Ports the Azure `optional/aks-deploy` (AKS→EKS,
Front Door→CloudFront, Service Tags→AWS `ip-ranges.json`). EKS nodes are private
and egress **only** through the VM-Series, constrained by a custom **External
Dynamic List** served from an EDL server in the MGMT VPC.

## Components
- `modules/eks_network` — dedicated EKS VPC, private node subnets, TGW attach,
  default route → TGW → FW (no IGW/NAT in the EKS VPC).
- `modules/eks_cluster` — private `aws_eks_cluster` + managed node group + IAM.
- `modules/edl_server` — Ubuntu+nginx in the MGMT VPC serving
  `/edl/eks-egress-{fqdn,ips}.txt`; a systemd timer regenerates them
  (`generate_eks_edl.py`: FQDN baseline + AWS `ip-ranges.json` for the region).
  **URL EDL entries carry a trailing slash** (PAN-OS wildcard requirement).
- `modules/wordpress` — Bitnami WordPress via Helm (`service.type=LoadBalancer`).
- `modules/cloudfront_wordpress` — CloudFront in front of the WordPress LB.
- EDL **rules** live in the panos workspace: `phase2-panorama-config` with
  `enable_edl=true` + `edl_server_ip=<edl ip>` creates the EDLs and an
  egress-allow rule placed **before** `spokes-outbound`.

## Order (load-bearing)
1. Root stack up (TGW + MGMT VPC exist).
2. `apply` this workspace **without** WordPress LB → creates EDL server + EKS VPC.
3. Run `phase2-panorama-config` with `enable_edl=true` and the EDL server IP, so
   the FW permits node-bootstrap endpoints **before** nodes join.
4. Node group + Helm WordPress converge; read the WordPress LB hostname
   (`kubectl -n wordpress get svc wordpress`) → set `wordpress_lb_hostname` →
   re-apply to create CloudFront.

## Inputs
Fill `terraform.tfvars` from the root outputs (`transit_gateway_id`,
`mgmt_vpc_id`, `edl_subnet_id`, `security_vpc_cidr`). See `terraform.tfvars.example`.

> Un-testable offline; validate against a live EKS + Panorama. `terraform
> validate` (aws + kubernetes + helm) is clean.
