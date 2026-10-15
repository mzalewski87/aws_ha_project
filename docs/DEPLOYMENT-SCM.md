# Deployment Guide — Path B: Strata Cloud Manager

> **STATUS: NOT YET LIVE-VERIFIED.** Path A (Panorama, [DEPLOYMENT.md](DEPLOYMENT.md))
> has run end-to-end on a real account. Path B has passed `terraform validate` /
> `fmt` and its REST schemas were read from the pan.dev OpenAPI, but it has not
> yet been applied. Items that need confirming against a live tenant are marked
> **[VERIFY LIVE]** here and in the code. Update this banner when they are closed.

Path B is the same AWS deployment (VPCs, TGW, VM-Series Active/Passive HA pair,
GlobalProtect, DC + PKI, Guacamole) with **Strata Cloud Manager instead of
Panorama** as the management plane. Select it with `management_mode = "scm"`.
Everything not about management is shared with path A — read
[DEPLOYMENT.md](DEPLOYMENT.md) for the shared phases (networking, DC, PKI, Region B)
and use this guide for what differs.

## What changes vs path A

| Concern | Path A (Panorama) | Path B (SCM) |
|---|---|---|
| Management plane | Panorama EC2 + EBS log disk | SCM tenant (no EC2) |
| Bootstrap init-cfg | `panorama-server=<ip>`, `vm-auth-key`, `tplname`, `dgname` | `panorama-server=cloud` + registration PIN |
| Activation | manual serial + licence + device cert (OTP) on Panorama | none — device certificate PIN is in the firewall's init-cfg |
| Config container | template stack + device group | one SCM **folder** |
| Per-device values | template variables + raw-XML override script | `scm_variable` with `device =` (native) |
| Config workspace | `phase2-panorama-config/` (`panos` provider) | `phase2-scm-config/` (`scm` provider) |
| Registration | `register-fw-panorama.sh` | `scm-onboard-fw.sh` |
| Commit / push | `configure-panorama.sh commit` | `scm-push.sh` |
| HA | `configure-ha.sh` (SSH per firewall) | `scm-ha.sh` (SCM `/ha-configurations`) |
| Version rule | Panorama >= firewall PAN-OS | none (guard is skipped) |
| Logging | Panorama log collector | Strata Logging Service (tenant-side) |
| Jump host | inside `modules/panorama` | `modules/ssm_jumphost` (still needed) |

## What the `scm` provider cannot do (and what covers it)

Verified against provider v1.0.13's schema and the pan.dev OpenAPI:

| Needed | Why not Terraform | Covered by |
|---|---|---|
| Virtual router | provider only has the Advanced Routing Engine `logical_router`; the AWS HA plugin's route failover is live-verified only with the legacy VR | `scripts/scm-virtual-router.sh` (REST) |
| HA (incl. HA2 on `ethernet1/1`) | no HA resource; `ethernet_interface` has no `ha` mode | `scripts/scm-ha.sh` (REST) |
| GP portal + gateway | **SCM exposes no NGFW portal/gateway object in its public API** | device-local XML API — **to be built and verified live** |
| GP tunnel settings | not in the provider | REST `/gp-tunnel-settings` — **to be built live** |

Prisma Access Agent was evaluated and rejected: its API (`MobileAgent`) belongs to
Prisma Access (cloud), so it cannot replace GlobalProtect on our own VM-Series.

## Phase B0 — Prerequisites

Everything in [Phase 0](DEPLOYMENT.md#phase-0--prerequisites) that concerns the
firewalls (Marketplace AMI for **VM-Series**, auth-code credit pool, key pair) —
but **not** the Panorama AMI, serial or OTP.

Additionally:
- **SCM tenant** and its **TSG ID**.
- **Service account** with rights to edit configuration and push (client ID +
  secret). Keep the secret out of the repo: export it, or `source` an untracked
  file. The scripts read `SCM_TSG_ID`, `SCM_CLIENT_ID`, `SCM_CLIENT_SECRET`.
- **Device-certificate registration PIN (ID + value)**, generated in the Customer
  Support Portal. Registration PINs expire (path A hit this: an expired PIN blocks
  the device-certificate fetch), so generate it last, right before the firewalls
  launch. The exact lifetime for this flow is not confirmed — treat it as short.
- **Software NGFW licensing** for the tenant (auth code / deployment profile).
- Terraform applies against SCM must use **`-parallelism=4`** (the auth API allows
  ~10 concurrent token requests per tenant).

## Phase B1 — Base networking, firewalls (root)

Root `terraform.tfvars`:

```hcl
management_mode           = "scm"
fw_auth_code              = "<BYOL auth code>"      # never commit
fw_registration_pin_id    = "<PIN id>"              # never commit
fw_registration_pin_value = "<PIN value>"           # never commit
```

Apply in the same order as path A's Phases 1a → 1b ([DEPLOYMENT.md](DEPLOYMENT.md)).
With `management_mode = "scm"` no Panorama instance is created; the SSM jump host
still is. There is **no Phase 2a** (no `vm-auth-key` handoff): the firewalls boot,
dial SCM using the PIN, and appear in the tenant.

## Phase B2 — SCM configuration

Run from `~/.config`-sourced credentials. Three-step, because the folder must
exist before devices can be moved into it, and per-device overrides need the
devices inside the folder:

```bash
source ~/.config/aws_ha_scm/secrets.env     # SCM_* (+ TF_VAR_scm_client_secret)
cd phase2-scm-config
cp terraform.tfvars.example terraform.tfvars  # fill tsg id / client id; secret via TF_VAR_*
terraform init
terraform apply -parallelism=4              # 1) folder + defaults + policy

cd ..
bash scripts/scm-onboard-fw.sh AWS-HA-Transit \
  fw1=<trust_cidr>,<untrust_cidr> fw2=<trust_cidr>,<untrust_cidr>
#   waits for both firewalls to connect, moves them into the folder,
#   writes phase2-scm-config/fw_devices.auto.tfvars.json   (git-ignored)

cd phase2-scm-config && terraform apply -parallelism=4   # 3) per-device overrides
cd ..
bash scripts/scm-virtual-router.sh AWS-HA-Transit
PRIMARY_SERIAL=... SECONDARY_SERIAL=... \
PRIMARY_MGMT_IP=... SECONDARY_MGMT_IP=... \
PRIMARY_HA2_IP=...  SECONDARY_HA2_IP=...  bash scripts/scm-ha.sh
bash scripts/scm-push.sh AWS-HA-Transit     # waits for the job; non-OK = failure
bash scripts/scm-verify.sh AWS-HA-Transit   # read-only: devices, HA, rule order
```

Pull the addresses from the root outputs `fw_mgmt_private_ips` and
`fw_ha2_private_ips`. Expect `scm-verify.sh` to show one firewall `active`, one
`passive`, and the Guacamole/GP allow rules **before** `deny-all`.

**[VERIFY LIVE]**
- The serial printed by `scm-onboard-fw.sh` is a plain number (the HA API needs
  it; the script aborts otherwise).
- The folder is created under `ngfw-shared` (SCM rejects the predefined `All` as a
  parent, error DC_0001) and inherits snippets from `All` and `ngfw-shared`
  (`default`, `Web-Security-Default`, `GlobalProtect-Default`,
  `Auto-VPN-Default-Snippet`). Check in `scm-verify.sh` that inherited rules do
  not pre-empt our allows.
- Rule order from `position = "pre"` + the `depends_on` chain.
- `loopback.N` the device assigns for `$gp_loopback` (SCM requires `$`-style
  loopback names).
- The push response's job-id field (the spec doesn't document it).

## Phase B3 — DC, PKI

Identical to path A (these are AWS/Windows, not management-plane).

## Phase B-GP — GlobalProtect

The portal, gateway and the gateway's network-side tunnel node
(`network/tunnel/global-protect-gateway`) have no SCM object, so they are applied
to each firewall's local configuration over the XML API, exactly as path A did
for the tunnel node. The tunnel-mode lessons in CLAUDE.md apply unchanged
(two config subtrees, tunnel interface must be in a VR, client IP pool in exactly
one place, inbound GP is intrazone `untrust→untrust` and needs its own allow).

**[VERIFY LIVE — highest risk of path B]** that locally-defined GP config survives
SCM pushes. If it does not, the order becomes: push from SCM first, then apply the
local GP config, and re-apply after every push. This script is intentionally
**not written yet**: path A's GP bring-up needed live iteration against real
commit errors, and XML written blind would be rewritten anyway.

## Guacamole (both paths)

Set in root `terraform.tfvars` (requires the custom domain):

```hcl
enable_custom_domain = true
custom_domain_subdomain_zone = "<your delegated subdomain>"
enable_guacamole     = true
guacamole_hostname   = "rdp"          # -> https://rdp.<subdomain>/guacamole/
```

- Internet-facing ALB (ACM cert, DNS-validated in the Route53 zone) → Guacamole
  host in the mgmt VPC → RDP to the DC **over the TGW, i.e. through the
  firewalls** (inspected and logged). No RDP port is exposed to the internet.
- The admin password is generated and stored in Secrets Manager
  (`terraform output guacamole_admin_secret_arn`); the default `guacadmin`
  account is deleted at first boot. **TOTP is mandatory**: each user enrols a
  device on first login.
- The ALB is open to the internet by default (`alb_ingress_cidrs`); narrowing it
  is the cheapest extra hardening.
- Firewall side: rule `guacamole-rdp-to-dc` (`trust→trust`, `ms-rdp`, source =
  the guac subnet) in both `modules/panorama_config` and `phase2-scm-config`; the
  catch-all `deny-all` would otherwise block this intrazone traffic.
- **[VERIFY LIVE]** TOTP activation through the container's env vars
  (`EXTENSIONS=auth-totp` / `TOTP_ENABLED=true`).

## Teardown

`terraform destroy` per workspace in reverse order. Path B leaves objects in the
SCM tenant: delete the `AWS-HA-Transit` folder and the two devices in the SCM UI
(or via the API) so a re-deploy starts clean, and note each redeploy consumes
BYOL licence credits as in path A.
