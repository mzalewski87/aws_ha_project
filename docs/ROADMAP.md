# ROADMAP — AWS VM-Series HA + Multi-Region GlobalProtect

Companion to `ARCHITECTURE-DECISION.md`. This is the phased build order for the
project. The `panos` provider connects to Panorama on every `plan`, so Panorama
configuration lives in its own workspace (`phase2-panorama-config/`) to keep it
out of the root plans.

## Guiding sequence

1. Networking/base → 2a. Panorama config workspace → 1b. FW + LB + routing +
apps → 2b. FW registration on Panorama → 3. DC/extras → GP layer → Region B.

## Phase 0 — Prerequisites (per AWS account)

- **Subscribe to VM-Series + Panorama BYOL AMIs** in AWS Marketplace. Script:
  `scripts/accept-marketplace-terms.sh`.
- VM-Series **auth codes** with credit balance.
- Fresh **registration PIN** (for the device-cert flow).
- IAM: deployer permissions; decide state backend (S3 + DynamoDB lock).
- Key pair (or `create_ssh_key`) for FW/instances.

## Phase 1a — Base networking + Panorama (root, `-target`)

- `modules/vpc` — mgmt VPC, security/transit VPC, spoke VPCs; subnets across
  ≥2 AZs; IGW; NAT GW; route tables; security groups.
- `modules/transit_gateway` — TGW + attachments + TGW route tables (appliance
  mode on security VPC attachment).
- `modules/bootstrap` — init-cfg render + user-data (IMDSv2); IAM role /
  instance profile (incl. **HA-plugin** EC2 permissions + SSM + optional S3).
- `modules/panorama` — Panorama EC2 BYOL + EBS log volume + EIP/mgmt + SSM.
- Handoff: Panorama instance ID for the SSM port-forward in Phase 2a.

## Phase 2a — Panorama config (separate `panos` workspace)

- `phase2-panorama-config/` — wait-for-API, hostname/serial/license,
  **generate vm-auth-key** → write `../panorama_vm_auth_key.auto.tfvars`
  (or SSM Parameter Store), template stack + device group, interfaces, zones,
  virtual router(s), static routes, NAT + security policy, log-collector
  (disk-pair/DLF/collector-group/ES-reinit restart), commit.
- `modules/panorama_config` — the panos resource definitions consumed here.
- Log-collector setup (`scripts/setup-log-collector.sh`, phase2
  `enable_log_collector`): disk-pair + Collector Group bind + commit-all
  log-collector-config.
- Access via **SSM port-forward** (see `scripts/configure-panorama.sh`).

## Phase 1b — Firewalls + LB + routing + app (root, `-target`)

- `modules/firewall` — 2× VM-Series **Active/Passive HA** (ENIs: mgmt/untrust/
  trust + HA2; source/dest check disabled; EIP on active; IAM instance profile;
  multi-AZ placement). Consumes vm-auth-key from Phase 2a.
- `modules/loadbalancer` — NLB for **app inbound** (Apache) — **not** for GP.
- `modules/routing` — spoke route tables → TGW; overlay/return routing.
- `modules/cloudfront` — CDN in front of the app.
- `modules/spoke1_app` — Apache-on-EC2 hello-world.
- Handoff: FW serials → Phase 2b.

## Phase 2b — Register FWs on Panorama

- `scripts/register-fw-panorama.sh` — SSM tunnels to FWs+Panorama, read
  serials, add to Panorama mgmt-config + DG + TS, `commit-all`.

## Phase 3 — DC + extras (root, `-target` + optional)

- `modules/spoke2_dc` — Windows Server EC2 domain controller.
- `optional/dc-promote/` — promote to AD DS (SSM RunCommand / user-data).

## Phase GP — GlobalProtect layer (Region A)

- `modules/globalprotect` (or GP portions of `panorama_config`) — tunnel
  interface, IP pool, gateway, portal, external gateway list, certs, auth
  profile (local or SAML/cert), security+NAT policy. See
  `docs/globalprotect-design.md`.
- Deliverable: working HA GP Portal + Gateway in Region A.

## Phase R2 — Region B + global resilience

- Re-instantiate VPC/TGW/bootstrap/firewall/GP for **Region B** via the
  `region_stack` wrapper under the region-aliased provider + cross-region TGW
  peering (`cross_region.tf`) so Region B FWs reach the single Region A Panorama.
- Add Region B to the portal's external gateway list (`gp_external_gateways`)
  for multi-region GP failover.
- `modules/global_accelerator` — anycast front-end over per-region portal
  EIPs; health checks; failover.
- Region B replica AD DC for region-outage AD/LDAP authentication failover.
- Deliverable: survives a whole-region outage.

## Optional — EKS + WordPress + EDL

- `optional/eks-deploy/` — `eks_network`, `eks_cluster`, `edl_server` (EDL in
  mgmt VPC, trailing-slash wildcard rule), `wordpress` (Helm),
  `cloudfront_wordpress`, and the panos EDL rules in `phase2` (`edl.tf`,
  `enable_edl`) placed `before` spokes-outbound. See `optional/eks-deploy/README.md`.

## Deferred to v2

- Partial adoption of `terraform-aws-swfw-modules`.
- HA-Panorama pair; autoscale (ASG) FW tier; GWLB for east-west scaling.

## Conventions

- Conventional Commits.
- `terraform validate` + `fmt -check` on root **and** the phase2 workspace.
- No secrets in the tree — only `*.tfvars.example` templates are committed; real
  `*.tfvars`/`*.pem` are git-ignored.
