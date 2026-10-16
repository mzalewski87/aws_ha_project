# Deployment Guide — Path B: Strata Cloud Manager

> **STATUS: LIVE-VERIFIED in Region A on a fresh AWS account (2026-10), but NOT yet from
> a clean single-pass redeploy.** Verified end to end: firewalls on PAN-OS 12.2.3
> onboard to SCM; folder config (ARE logical router, interfaces, zones, NAT, policy) is
> pushed and committed on both; Active/Passive HA is configured from SCM and a forced
> failover moves the EIP, the floating address and the TGW route; Guacamole (TOTP) reaches
> the domain controller through the firewalls; a GlobalProtect client connects with a
> Let's Encrypt certificate and reaches the DC.
>
> The deployment was reached by iterating: several fixes were applied to a running
> environment (firewall replacement, Guacamole host replacement), so **a clean
> from-scratch run of the final code has not been done**. Also NOT verified: the AD CS
> PKI build (the Sub CA never registered with SSM in this run), Region B / Global
> Accelerator in path B, and GP client connection time during a failover.
> Path A (Panorama, [DEPLOYMENT.md](DEPLOYMENT.md)) is unchanged and was verified earlier.

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
| Version rule | Panorama >= firewall PAN-OS | none (guard is skipped); path B runs the newest PAN-OS SCM supports |
| Routing engine | legacy virtual router | **ARE** — `scm_logical_router`; init-cfg `plugin-op-commands=advance-routing:enable` |
| Logging | Panorama log collector | Strata Logging Service (tenant-side) |
| Jump host | inside `modules/panorama` | `modules/ssm_jumphost` (still needed) |

## Routing: ARE (logical routers), not the legacy virtual router

Path B uses the Advanced Routing Engine. Two reasons, both seen live: SCM-managed
firewalls report `advanced_routing: true`, and SCM's own **bootstrap push**
(`NGFW-Bootstrap-Push`, owner `bootstrapsvc`) is rejected when interfaces are not in
a logical router (`Interface ethernet1/2 has no logical-router configured`) — which
is exactly what a legacy virtual router created over REST produced. The router is a
Terraform resource (`scm_logical_router`: one `default` VRF with the four interfaces
and two static routes whose next hops are the folder variables), and init-cfg turns
ARE on from the first boot. **[VERIFY LIVE]** the AWS HA plugin's route/EIP failover
with ARE (path A's failover was verified only with the legacy virtual router).

## Firmware

The firewalls launch on the newest PAN-OS that is both in the Marketplace for
VM-Series BYOL and listed by SCM (`GET /config/device/v1/software-versions`) — 12.2.3
at the time of writing. Set `vmseries_version` in root `terraform.tfvars`. An older
release (11.1.15) failed SCM's bootstrap push on a tenant DLP data profile that
references an application (`general-browsing`) it does not know. Changing the
version recreates the firewalls, consumes BYOL activations again and gives them new
serials: re-run `scm-onboard-fw.sh`, regenerate the per-device variables and the HA
config, and delete the old (disconnected) devices from SCM.

## What the `scm` provider cannot do (and what covers it)

Verified against provider v1.0.13's schema and the pan.dev OpenAPI:

| Needed | Why not Terraform | Covered by |
|---|---|---|
| HA (incl. HA2 on `ethernet1/1`) | no HA resource; `ethernet_interface` has no `ha` mode | `scripts/scm-ha.sh` (REST) |
| GP portal + gateway | **SCM exposes no NGFW portal/gateway object in its public API** | device-local XML API — `scripts/scm-gp-local.sh` (live-verified) |
| GP tunnel settings | not in the provider | not used: the client IP pool and split tunnel are in the local gateway config |

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
- **Software NGFW licensing and — critically — an ACTIVATED deployment profile on
  the target tenant.** Creating the deployment profile (and getting its auth code)
  is not enough: it must be **activated against the SCM tenant (TSG) the firewalls
  will join**, in the Palo Alto Networks portal, **before the firewalls boot**.
  - You already have an SCM tenant: select that tenant when activating the profile.
  - You have no tenant yet: create one first (provision the *Strata Cloud Manager*
    app for a TSG), then activate the profile against it.
  Without this step the firewalls license fine and even fetch a valid device
  certificate, but never learn their SCM endpoint and never connect — see
  [Troubleshooting](#troubleshooting). Exact portal menu names differ between
  portal versions; the contract is "profile activated for this tenant".
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
  <serial1>=<trust_cidr>,<untrust_cidr> <serial2>=<trust_cidr>,<untrust_cidr>
#   (serials from `show system info` — NOT hostnames: DHCP overrides the hostname)
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
- Interface naming (learned from the first live apply): SCM rejects raw port names
  (`ethernet1/3`, `tunnel.1`) at folder level. Folder interfaces are `$variable`
  names (`$untrust_if`, `$trust_if`, `$gp_tunnel`, `$gp_loopback`) with the physical
  port in `default_value`; zones, NAT and the virtual router reference the `$`
  names. Confirm on the device that they resolve to `ethernet1/3`, `ethernet1/2`,
  `tunnel.1`, `loopback.1`.
- The push response's job-id field (the spec doesn't document it).

## Phase B3 — DC, PKI

Identical to path A (these are AWS/Windows, not management-plane).

## Phase B-GP — GlobalProtect

**Live-verified (PAN-OS 12.2.3, ARE, Let's Encrypt):** a GlobalProtect client
connected to the portal, landed on gateway `gw-a`, and could ping the domain controller.

The portal, gateway and the gateway's network-side tunnel node
(`network/tunnel/global-protect-gateway`) have no SCM object, so `scripts/scm-gp-local.sh`
writes them to the firewall's LOCAL configuration over the XML API. Everything else GP
needs is in `phase2-scm-config` (tunnel interface, `vpn` zone with user identification,
loopback bind address, ARE routing, inbound-GP allow rule).

```bash
# env (untracked file): SCM_*, GPAPI_PASSWORD, GP_USER_PASSWORD, JUMP_INSTANCE_ID, KEY_FILE,
#                       GW_FQDN, CERT_CN
bash scripts/scm-gp-local.sh admin         # temporary local superuser `gpapi`
bash scripts/scm-gp-local.sh build         # cert (placeholder), TLS, auth, tunnel node, gateway, portal
bash scripts/scm-gp-local.sh letsencrypt   # real certificate (see below)
bash scripts/scm-gp-local.sh cleanup       # delete `gpapi` again
```

What was proven live, and what was not:
- Local config **survives SCM pushes**, and the HA pair **copies it to the passive unit**
  (`Running Configuration: synchronized`). After a forced failover the same public address
  kept serving the portal, with no DNS change.
- The script picks the **active** unit itself (SCM `ha_state`). Changes made on the passive
  unit are overwritten by the next HA sync — a first run on the wrong unit cost a pass.
- The firewall needs the GP **client package** only if the portal should serve the installer;
  it is not needed for a client that is already installed.

### Certificate: Let's Encrypt, not a self-signed one
A self-signed certificate whose subject equals its issuer must be flagged as a CA, and a CA
certificate carries only `keyUsage = Certificate Sign`. Browsers then refuse the site with
`ERR_SSL_KEY_USAGE_INCOMPATIBLE`. `build` therefore creates a *placeholder*; set
`custom_domain_cert_mode = "letsencrypt"` (+ `custom_domain_letsencrypt_email`) in the root
`terraform.tfvars`, apply `module.custom_domain` (DNS-01 in the delegated Route53 zone, so
the NS delegation must be live), then run `scm-gp-local.sh letsencrypt`. One wildcard
covers the portal and every gateway name.

### Gotchas found building it (each one failed a real commit)
- Portal `portal-config` requires `custom-login-page`, `custom-home-page` and
  `custom-help-page` (`factory-default`).
- TLS `max-version` must be `tls1-2` — the keyword `max` is rejected.
- A commit can be refused with "A commit is pending"; retry after the running one ends.
- The commit job's result is the first **non-empty** `<result>` element.

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

## Troubleshooting

**Firewalls never appear in SCM (`GET /config/setup/v1/devices` returns `[]`).**
On the firewall CLI (SSH via the SSM jump host) run `show cloud-management-status`:

| Output | Meaning |
|---|---|
| `Endpoint:` **empty**, `Connected: no`, DNS/TCP/SSL status empty | The firewall is cloud-managed but was **never given an SCM endpoint**: its serial is not associated with a tenant. The deployment profile was not activated for the tenant (see Phase B0). Licensing and `show device-certificate status` can both look perfectly healthy in this state — that is the trap. |
| Endpoint set, DNS/TCP/SSL failing | Network problem: outbound HTTPS/DNS from the firewall mgmt subnet (NAT, route, security group egress). |

Once the profile is activated the devices show up under *Available Devices* within
minutes with no reboot — they keep retrying.

**Hostname is `ip-10-10-0-11`, not `fw1`.** The firewalls take their hostname from
DHCP (`dhcp-accept-server-hostname=yes` overrides the init-cfg `hostname=`).
`scm-onboard-fw.sh` therefore takes **serial numbers** (`show system info`); in SCM
the device `name` is the serial and the `id` equals it.

**Other live findings:** SCM rejects `All` as a parent folder (use `ngfw-shared`) and
raw port names at folder level (use `$variable` names + `default_value`); see
[Phase B2](#phase-b2--scm-configuration).
