# GlobalProtect Multi-Region Design (AWS)

> Companion to [ARCHITECTURE-DECISION.md](ARCHITECTURE-DECISION.md).
> This is the design the `modules/globalprotect/` + `modules/panorama_config/`
> (GP portions) + `modules/global_accelerator/` implement.

## Goal

A GlobalProtect **Portal** + **Gateway** service that:
- terminates remote-user VPN (SSL-VPN + IPSec) on public IPs,
- is **HA within a region** (Active/Passive FW pair, failover invisible to
  clients),
- **survives a whole-region outage** (second region + native gateway failover +
  Global Accelerator for the portal).

## Components

### 1. Portal
- Delivers agent config: auth, app settings, and the **external gateway list**.
- One logical FQDN (e.g. `vpn.example.com`) pre-seeded in the client.
- Served by the FW(s); the public entry is **Global Accelerator** (anycast) in
  front of each region's portal EIP so the FQDN survives a region loss.

### 2. Gateway (one per region)
- Terminates the tunnel; assigns IP-pool addresses; enforces security policy.
- Advertised in the portal's external gateway list, e.g.:
  - `gw-eu-central.example.com` priority 1 (Region A)
  - `gw-eu-west.example.com`    priority 2 (Region B)
- Agent uses **best available** (SSL response time) → automatic cross-region
  failover with **no LB** on the gateway path.

### 3. Global Accelerator (portal front-end)
- 2 static anycast IPs; listeners TCP 443 (+ UDP 4501 if IPSec via portal path);
  endpoint groups = per-region portal EIP; health checks per region.
- Alternative (not chosen): Route 53 failover/latency + health checks.

## PAN-OS objects to configure (via Panorama template/DG → panos provider + XML)

Built on top of the existing `panorama_config`:
- **Tunnel interface** `tunnel.1` (+ per-region variant), assigned to a
  dedicated **`vpn`/`corp`-user zone**.
- **IP pool(s)** per gateway (non-overlapping across regions).
- **GlobalProtect Gateway** config: interface (untrust/EIP), tunnel interface,
  auth profile, client-config (IP pool, split-tunnel include/exclude routes,
  DNS).
- **GlobalProtect Portal** config: portal interface, auth profile, agent config
  with the **external gateway list** (all regions + priorities), root-CA for the
  agent to trust gateway certs.
- **Certificates**: portal + gateway **server certs** (public CA preferred;
  ACM-issued cert must be exported and imported into PAN-OS — PAN-OS cannot
  consume ACM directly). Certificate profile for client/machine cert auth if
  used.
- **Auth**: `authentication-profile` → SAML (Okta/Entra; see PANW
  `globalprotect-okta` ref) or LDAP or client-cert. SAML metadata / IdP cert
  imported to the template.
- **Security policy**: allow `vpn-zone` → trust/spokes for permitted apps;
  deny-all baseline.
- **NAT policy**: SNAT for GP users egressing to internet/spokes as needed
  (mirror the existing DNAT/SNAT patterns).

## HA & failover layering (summary)

| Failure | Covered by |
|---------|-----------|
| Single FW instance dies | Active/Passive HA (peer takes EIP/route) |
| Whole AZ dies | Multi-region (other region's gateway via GP-native failover); intra-region cross-AZ HA plugin |
| Whole region dies | GP-native gateway failover (agent → next region) + Global Accelerator moves portal traffic to healthy region |
| Panorama dies | Firewalls keep running last-pushed config; mgmt only affected. HA-Panorama = later enhancement |

## Region-parameterization requirements (multi-region-ready foundation)

- `region` is an input; providers aliased per region (`aws.region_a`,
  `aws.region_b`).
- Non-overlapping CIDRs per region; GP IP pools non-overlapping.
- Certs/auth shared via Panorama template (single source of truth).
- Global Accelerator + cross-region wiring isolated in `modules/global_accelerator/`
  and only enabled in the Region-B phase (feature-flag / count).

## Phasing hook

Region A GP (portal+gateway on the HA pair) is delivered in the core phases;
Region B + Global Accelerator is a dedicated later phase — see `ROADMAP.md`.
