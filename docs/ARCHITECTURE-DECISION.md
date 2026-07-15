# Architecture Decision Record — AWS VM-Series HA + Multi-Region GlobalProtect

Status: **Accepted**. Companion: `globalprotect-design.md`, `ROADMAP.md`.

## Context

The primary goal is **resilient delivery of a GlobalProtect Portal + VPN Gateway
that survives a whole-AWS-region outage**. Around that core, the project also
provides centralized transit inspection, spoke VPCs (an Apache app and a Windows
domain controller), optional EDL and EKS, and a CDN — but GP resilience is the
north star.

## Decisions

### D1 — HA model: Active/Passive HA pair per region (NOT GWLB)

- Each region runs **two VM-Series in a PAN-OS Active/Passive HA pair** (HA1
  control + HA2 state sync), with EIP / secondary-IP or route-table failover via
  the **PAN-OS AWS HA plugin** (IAM instance profile required).
- **Why:** a GlobalProtect Portal/Gateway terminates **client-dialed VPN on a
  public IP**. GWLB is a transparent GENEVE bump-in-the-wire with no
  client-addressable per-FW public IP — the wrong tool for VPN termination.
  Active/Passive keeps a single stable public entry per region, with failover
  invisible to clients.
- GWLB is **not** used for the GP path. It may be revisited only for east-west /
  transit inspection scaling in a later iteration; not in scope for v1.
- Native HA configuration (Setup/Election/Control-Link/Data-Link) has no `panos`
  provider resource and is device-local (different peer-ip/priority per
  firewall), so it is pushed via `scripts/configure-ha.sh` (direct SSH, per
  firewall). Note: `ethernet1/1` must be the HA2 link — an AWS platform
  requirement — so the HA2 ENI is attached at `device_index=1`.

### D2 — Regional resilience: multi-region, delivered in phases

- **Region A first**, fully working end-to-end (Portal + Gateway + Panorama +
  automation). **Region B** (second full stack) + global front-end is a later
  phase. The foundation is **multi-region-ready from day one**: region is a
  variable, the provider is aliased per region, there are no hardcoded
  AZ/region/CIDR assumptions, and all naming is region-scoped.
- **Why phased:** avoids a big-bang 2-region + cross-region + GA + cert/DNS
  bring-up that is hard to debug. Delivers a working, HA GP early, then layers
  regional resilience without rework.

### D3 — Portal global entry: AWS Global Accelerator

- The GP **Portal** FQDN resolves to **Global Accelerator** (2 static anycast
  IPs), which health-checks the per-region portal endpoints and fails over
  cross-region in under a minute. Supports TCP 443 (SSL) and UDP 4501 (IPSec).
- **Why over Route 53 failover:** anycast + sub-minute failover independent of
  DNS TTL/cache; a single stable IP set the client keeps forever. Route 53
  latency/failover is recorded as the alternative, not chosen.

### D4 — GP Gateways rely on GlobalProtect-native selection

- Each region exposes a **gateway**; the Portal's **external gateway list**
  carries all regions with priorities; the agent selects **best available** (SSL
  response time) and fails over natively when a region is unreachable. **No load
  balancer for gateway failover** — this is a built-in GP capability.

### D5 — Centralized inspection: Transit Gateway (appliance mode)

- Spoke VPCs + the security VPC attach to a **Transit Gateway**; TGW route
  tables force spoke↔spoke and spoke↔internet through the security-VPC FWs.
  **`appliance_mode_support = enable`** on the security-VPC attachment (required
  for flow symmetry across AZs).
- **Why over VPC peering:** a scalable centralized hub matching PANW's AWS
  reference architectures; peering is non-transitive and doesn't scale to the
  spoke count.

### D6 — Central management: single Panorama (EC2 BYOL)

- One Panorama manages **all** firewalls in **all** regions. HA-Panorama is a
  possible later enhancement, not v1. Log-collector setup (disk-pair, DLF,
  collector group, ES-reinit restart) is PAN-OS-side and cloud-agnostic.

### D7 — Bootstrap: user-data inline init-cfg (S3 optional)

- Prefer **EC2 user-data** carrying `init-cfg.txt` (base64, read via IMDSv2).
  Introduce an **S3 bootstrap bucket** (with S3 gateway VPC endpoint + IAM
  `s3:GetObject`) only if `bootstrap.xml` / a large content bundle is required.
- **Why:** keeps the bootstrap path off any PUT-based, SSL-inspected upload flow.

### D8 — Management-plane access: SSM Session Manager (not Bastion)

- The `panos` provider + XML-API automation reach Panorama/FWs via **SSM
  Session Manager port-forwarding** through an SSM jump host (PAN-OS has no SSM
  agent). Requires SSM agent + instance-profile SSM permissions (+ SSM VPC
  endpoints if there is no NAT egress).

### D9 — Keep the project's own modules (don't wholesale-adopt swfw-modules)

- Author project-owned modules; **read** `terraform-aws-swfw-modules` as the
  authoritative reference for resource shapes, HA-plugin IAM, ENI ordering, and
  TGW/GWLB wiring. Revisit partial adoption in a v2 ROADMAP.

### D10 — Service choices

- Front Door → **CloudFront** (+ optional WAF); container platform → **EKS**;
  management access → **SSM**; workload identity → **IAM instance profile**;
  object storage → **S3**; block storage → **EBS**. IMDSv2 is required on all
  instances.

## Consequences / risks

- Active/Passive cross-AZ failover for a public EIP is the trickiest AWS-specific
  mechanic. Multi-region + GP-native gateway failover mitigates whole-AZ loss
  regardless of the intra-region choice.
- Global Accelerator adds cost; documented Route 53 fallback (D3).
- Larger scope than a pure GP project because it also includes
  transit/EDL/EKS/DC — sequenced in the ROADMAP so GP lands first.
