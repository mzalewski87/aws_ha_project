# Deployment Guide — Path B: Strata Cloud Manager

> **STATUS: LIVE-VERIFIED in Region A on a fresh AWS account (2026-10), including a
> teardown and a second deployment from the repository code alone.**
> Verified: firewalls on PAN-OS 12.2.3 (ARE) onboard to SCM; the folder configuration
> (logical router, interfaces, zones, NAT, policy) applies in one pass and is pushed and
> committed on both firewalls; Active/Passive HA is configured from SCM and a forced failover
> moves the EIP, the floating address and the TGW route; Guacamole (TOTP, no default account
> from first boot) reaches the domain controller through the firewalls; a GlobalProtect
> client connected and reached the DC (first deployment); on the second deployment GP built
> by `scripts/scm-gp-local.sh` survives a forced failover when it exists on both units.
>
> **Not verified:** a GlobalProtect *client* session on the second deployment (it used a
> Let's Encrypt *staging* certificate, which clients do not trust); the AD CS PKI build (the
> Sub CA never registered with SSM in the first run); Region B / Global Accelerator in
> path B; GP session behaviour *during* a failover (only the state after it was checked).
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

### Upgrading a running pair in place: `scripts/scm-upgrade.sh`
Some features need a newer release than the Marketplace image (Frontier Virtual Patching needs
12.2.4+, the newest image is 12.2.3). `scm-upgrade.sh <folder> <version>` upgrades the pair
through an SCM *upgrade rule* (match: folder) and *schedule* (download, then install; HA
orchestration on). It was run live, 12.2.3 -> 12.2.4, and the GlobalProtect portal still answered
with its Let's Encrypt certificate afterwards (local configuration survives). Where the live API
differs from the OpenAPI document — each cost a failed run:
- **Dates are `YYYY/MM/DD`.** `YYYY-MM-DD` is rejected as `invalid date` for *every* value, which
  looks like a time-zone or past-time problem and is neither.
- **`job_type` is `download-install-reboot`.** `install` is "not an allowed keyword" (the OpenAPI
  enum says it is valid). Omitting `job_type` is accepted but the schedule then did nothing at its
  start time.
- **Start times are UTC.** A time that was still ahead in UTC but already past in Warsaw was
  accepted. Sending local time made a schedule wait two hours.
- **`GET /software-upgrade-status` stays an empty list** during a real, successful upgrade, so it
  is not usable as the completion signal. The script waits until every firewall of the folder
  reports the target version, is connected again and the pair is active/passive.
- Both firewalls came back within seconds of each other (their uptimes differed by ~3 s), so
  plan for an outage of a few minutes rather than a rolling, traffic-preserving upgrade — the HA
  orchestration did not visibly stagger the units.
- The script refuses to start unless every firewall of the folder is connected, and removes its
  own schedule when it finishes. A schedule left enabled keeps a start time in the past.

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

Identical to path A (these are AWS/Windows, not management-plane), with one ordering rule:
**run it only after the SCM configuration has been pushed to the firewalls (Phase B2).** The
spoke VPCs reach the internet through the firewalls, and until they carry NAT and policy the
DC's SSM agent never comes online — the `create-ad-test-user` step then waits 20 minutes and
fails, and a second run is needed.

### The PKI chain is a separate step (`scripts/setup-pki.sh`)
Terraform only creates the two CA *hosts*; the certificate chain is built by
`scripts/setup-pki.sh` (SSM RunCommand only — it does not need Panorama or SCM) and
`scripts/setup-machine-autoenroll.sh` (autoenrollment policy). Both ran live on path B. Run
them after the DC is up and the `admin` account exists. Findings, each fixed in the scripts:

- **The issuing CA host can end up outside the domain.** Its user-data retries the join for
  ~20 minutes and gives up. If the DC is not ready or the join account does not exist yet (it is
  created later), the CA stays in `WORKGROUP` and `Install-AdcsCertificationAuthority` fails with
  the misleading *"The user name or password is incorrect"*. `setup-pki.sh` now checks
  membership and joins the host itself (with a restart) before going on.
- **Publishing the root into AD silently did nothing.** `certutil -dspublish` ran as SYSTEM
  (a computer account) with its output sent to `Out-Null`; the *Certification Authorities*
  container stayed empty while the step reported success, so no domain member trusted the root.
  The script now publishes as a domain admin, prints certutil's exit codes and **verifies the
  container**, failing if the root is missing. After it, the DC shows the root in its Trusted
  Root store.
- **A re-run needs the root powered on** (the script stops it at the end, by design); the
  helper that wraps it starts it first.
- **Known gap — the root's CRL is not in AD.** `certutil -dspublish -f root.crl` fails with
  `ERROR_DS_REFERRAL` (`DC=UnavailableConfigDN`) because the root is a standalone, non-domain
  CA. The chain builds and the issuing CA works, but its CDP entries name the offline root host,
  so revocation checking of the root by clients is not covered. Not fixed yet.
- The decryption setup (`setup-ssl-decrypt.sh`) uses Panorama and has **not** been ported to SCM.

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

**Run every mode on EACH firewall of the pair, not only the active one.** Local configuration
(the GP objects *and* the temporary `gpapi` admin) is **not replicated** between the two
SCM-managed peers: a local commit warns "the running configuration is not currently
synchronized to the HA peer, therefore this commit will only be applied to the local device".
This was learned the hard way — GP built on the active unit, then a forced failover and the
portal did not answer (`HTTP 000`), because the new active unit had no GP configuration at
all. The script targets the active unit by default (`FW_IP` overrides it), so call it once per
unit, e.g. `FW_IP=<mgmt ip> scripts/scm-gp-local.sh build`.

What was proven live:
- Local config **survives SCM pushes** (a test login banner was still in `running config`
  after a push).
- With GP built on **both** units, a forced failover leaves the same public address serving
  the portal and the gateway from the new active unit, with no DNS change.
- Do not use `request high-availability sync-to-remote running-config` as a shortcut: it
  copies the whole configuration, including interface addresses that SCM sets per device.
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
- The gateway's `dns-server` takes `<member>` children; `<primary>text</primary>` is rejected
  ("has unexpected text").
- **`build` is re-run whenever GP settings change and must not undo the certificate.** It keeps
  `gp-le` when it already exists. (Earlier it re-pointed the TLS profile at the placeholder and
  a trusted portal became self-signed again — `tls_verify` 0 → 18.)
- **Moving Let's Encrypt from staging to production** needs a new ACME account (an account lives
  on one server) and the old staging objects cannot even be refreshed against production
  ("No account exists with the provided key"). `terraform state rm` the `acme_registration` and
  `acme_certificate`, flip `custom_domain_letsencrypt_staging`, apply `module.custom_domain`,
  then run `scm-gp-local.sh letsencrypt` on **each** unit.

### DNS for clients (domain join over the VPN)
The gateway pushes a DNS server and a DNS suffix to the GlobalProtect adapter:
`DNS_SERVER_PRIMARY` (default the DC, `10.13.0.10`), optional `DNS_SERVER_SECONDARY`, and
`DNS_SUFFIX` (default `panw.labs`, the root `dc_domain_name`). The AWS VPC resolver cannot see the
AD zone, so a client must resolve through the domain controller to join the domain; the suffix
lets short names resolve. Verified: after reconnecting, `ipconfig /all` shows the suffix and the
DC as DNS server, and `nslookup <domain>` returns the DC. The traffic itself (DNS, Kerberos,
LDAP, SMB, RPC to the DC) is not tested as an actual domain join.

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

## Optional run C — threat-prevention features (Advanced IP Defense, Frontier Virtual Patching)

Both are licensed through the deployment profile (`Advanced IP Defense`, `Advanced Threat
Prevention Plus` show up in the firewall's licences). They are optional and off by default.

### Advanced IP Defense — list-based variant (`ip_defense_mode = off | alert | block`)
PANW publishes the IP-reputation categories as **predefined external dynamic lists** (`panw-aipd-*`,
`panw-torexit-ip-list`, `panw-bulletproof-ip-list`, `panw-highrisk-ip-list`) that every SCM folder
inherits — nothing is created in the tenant. `phase2-scm-config` adds a rule at the top of the
pre-rulebase: `alert` is outbound `allow` + log only (opens nothing, blocks nothing), `block` adds
outbound and inbound `deny`. Verified live: a firewall expands a list into addresses
(`panw-aipd-c2-infra-ip-list`: 5500 valid entries; the PAN-OS list type is `predefined-ip`) and
`test security-policy-match` shows a listed address hitting `ipdef-outbound-alert` while an
ordinary one hits `spokes-outbound` — without sending any traffic to a real C2 address.

What this is **not**: the newer profile-based delivery (a profile attached to a *zone*, with a
cloud lookup per IP, PAN-OS 12.2.3+) has no object in the SCM API or the `scm` provider, so it
is not used here. Hits are visible by rule name in the traffic log (list-based variant), not as
`aipd` threat-log entries.

Gotcha (cost a pass): **a new SCM security rule is appended to the BOTTOM of the rulebase** — it
sat at position 10, behind `spokes-outbound`, and could never match. `relative_position = "top"`
fixes it, but only when the rule is *created*; changing the attribute on an existing rule did not
move it, so it was destroyed and recreated.

### Frontier Virtual Patching
Needs the Advanced Threat Prevention Plus licence **and PAN-OS 12.2.4 or later**; it is a
Vulnerability Protection profile setting (action per severity). The newest Marketplace image is
12.2.3, so the pair is upgraded in place (`scripts/scm-upgrade.sh`, above). Its pre-disclosure
signatures target vulnerabilities that are not public, so **they cannot be triggered on demand** and
PANW documents no test method; any "simulation" can only show that the profile is active and
read the logs for hits.

### Admin panel (read-only test console)

A small web panel for run C: sign in with an AD account, see each firewall's HA state and PAN-OS
version, and ask a firewall **which rule a simulated session would hit** (`test security-policy-match`)
— so Advanced IP Defense can be checked without sending a packet to a real malicious address. It can
also load a sample address from one of PANW's predefined IP lists. It only **reads**: no IAM right to
touch EC2, and the firewall account it uses has a custom role (`panel-ro`: XML-API operational commands only, no configuration access, commit, export or import). A plain `superreader` is not enough: it cannot run `test` / `request` / `show` through the XML API ("User not authorized to perform this operation"). Failover simulation is a later step.

Design: two hosts in two AZs of the management VPC (outside the firewall data path it reports on)
behind their own ALB, so a firewall failover, a host failure or an AZ failure does not take it down.
Login is an NTLM bind to the domain controller plus membership of the AD group `panel-admins`;
sessions are secure/HttpOnly/SameSite=Strict cookies, forms carry a CSRF token, failed logins are
rate-limited, every action is a JSON line in the host's journal (`journalctl -u panel`).

Enable and set up (needs `enable_custom_domain` and `enable_guacamole`-style DNS already in place):

```bash
# root terraform.tfvars:  enable_panel = true        (optional: panel_hostname = "panel")
terraform apply                                       # ALB, ACM cert, 2 hosts, secret
# phase2-scm-config:  applies the rule panel-ldap-to-dc (panel subnets -> DC, LDAP only)
cd phase2-scm-config && terraform apply

# one-off: the AD group and the read-only firewall admin (see the header of the script)
AWS_REGION=eu-central-1 DC_INSTANCE_ID=... DOMAIN_ADMIN_USER=... DOMAIN_ADMIN_PASSWORD=... \
  PANEL_USERS="admin" bash scripts/panel-setup.sh ad   # AD accounts only; gpuser is a local firewall user
AWS_REGION=eu-central-1 JUMP_INSTANCE_ID=... PANEL_SECRET_ARN=$(terraform output -raw panel_secret_arn) \
  FW_IPS="10.10.0.x 10.10.1.x" FW_ADMIN_USER=... FW_ADMIN_PASSWORD=... bash scripts/panel-setup.sh fw
```

Failover tests (page "Failover tests", `panel_enable_failover = true` by default): an AD account that
is in `panel-operators` (and `panel-admins`) can run
- **soft HA failover**: `request high-availability state suspend` on the active unit, wait for the
  peer to take over, then `functional` again;
- **hard failover**: stop the active unit's EC2 instance, wait for the takeover, start it again and
  wait until it is passive and synchronized;
- **recover**: start a stopped firewall / clear a suspended state after an interrupted run;
- **sync**: check running-configuration sync and repair it. Every failover test does the same
  check first: if the pair reports `not synchronized` it waits 20s (the state is often transient
  after a commit or an SCM push), then has the active unit push its configuration
  (`request high-availability sync-to-remote running-config`) and waits up to 4 minutes; only if
  that does not converge does it abort, before touching anything, and says the units have
  diverging local configuration. (Seen live: both units reported `not synchronized` for a while
  after a push, then recovered; HA1/HA2 were up throughout.)

While a test runs, the panel probes the GlobalProtect portal every second and shows the takeover
time and how long the portal was unreachable. The panel itself runs in the management VPC in two
AZs, outside the firewall path, so it stays up. Guard rails: operators only, a typed confirmation,
one test at a time per host, refusal to start unless the pair is a clean synchronized
active/passive pair, every step has a timeout, every start/finish is an audit line. The hosts'
IAM role can only `ec2:StopInstances`/`StartInstances` on the two firewall instances (plus
`DescribeInstances`). Create the operator group with `PANEL_OPERATORS="admin" ... panel-setup.sh ad`.
Progress lives in the memory of the host that started the test (the ALB is sticky); if that host
is replaced mid-test use "Recover" from the other one.

Known limits: the AD bind is NTLM over plain LDAP (not LDAPS) because the DC has no machine
certificate yet — the password is not sent in clear, but the exchange is not encrypted; the
rule matches App-ID `ldap` (if the firewall classes the NTLM bind differently the login times out
and the traffic log names the application).

## Teardown

Reverse order, one workspace at a time:

1. **SCM first.** A folder that still holds devices cannot be deleted and the API cannot
   delete devices, so move them out of the folder (`PUT /config/setup/v1/devices/<id>` with
   another folder), then `terraform destroy` in `phase2-scm-config`. Zones are deleted only
   after the rules that name them (an explicit `depends_on`); without it SCM answers
   `409 Node cannot be deleted because of references`.
2. **AWS:** `terraform destroy` in the root. Refresh the SSO session right before — a long
   destroy that starts on an expired token does nothing and still exits 0 through a wrapper.
3. **Afterwards** deactivate the firewalls' serials in the Customer Support Portal (this also
   removes them from SCM) so the licence credits are free again for the next deployment.

Things a teardown leaves or changes:
- The Route53 zone is destroyed, so a re-deployment gets **new name servers** and the parent
  registrar's delegation must be updated again. Resolvers cache the old delegation for the old NS
  TTL (about a day), so verify against the parent's authoritative server
  (`dig +norecurse @<parent ns> NS <zone>`), not the local resolver.
- Let's Encrypt production allows 5 identical certificates a week: use
  `custom_domain_letsencrypt_staging = true` while iterating.
- The Marketplace VM-Series root volume does not delete on termination; the firewall module sets
  `delete_on_termination = true`. After a destroy, list unattached EBS volumes anyway.

## Troubleshooting

**Firewalls never appear in SCM (`GET /config/setup/v1/devices` returns `[]`).**
On the firewall CLI (SSH via the SSM jump host) run `show cloud-management-status`:

| Output | Meaning |
|---|---|
| `Endpoint:` **empty**, `Connected: no`, DNS/TCP/SSL status empty | The firewall is cloud-managed but was **never given an SCM endpoint**: its serial is not associated with a tenant. The deployment profile was not activated for the tenant (see Phase B0). Licensing and `show device-certificate status` can both look perfectly healthy in this state — that is the trap. |
| Endpoint set, DNS/TCP/SSL failing | Network problem: outbound HTTPS/DNS from the firewall mgmt subnet (NAT, route, security group egress). |

Once the profile is activated the devices show up under *Available Devices* within
minutes with no reboot — they keep retrying.

**Endpoint still empty although the deployment profile lists the new serials.** Rule out the
network first: the firewall log (`show log system direction equal backward | match cloud`)
shows `app-cloud-engine ... gRPC connection to kcs.ace.tpcloud.paloaltonetworks.com:443 is
established` when egress works, and licence and device certificate are fetched over the same
path. If those are fine, the association simply has not propagated: after re-using serials'
slots (deactivating the old devices and activating new ones) SCM took a long time — tens of
minutes, with a restart of the firewalls in between that changed nothing — to drop the old
serials from *Available Devices* and list the new ones. Wait, and look at the tenant UI, before
suspecting the deployment. **Deactivating a device in the Customer Support Portal removes it from
SCM**; the API cannot delete devices.

**`scm-onboard-fw.sh` finds nothing.** It matches connected devices by management IP *and*
PAN-OS 12.x so stale entries of replaced firewalls (same IPs) are not picked up.

**Hostname is `ip-10-10-0-11`, not `fw1`.** The firewalls take their hostname from
DHCP (`dhcp-accept-server-hostname=yes` overrides the init-cfg `hostname=`).
`scm-onboard-fw.sh` therefore takes **serial numbers** (`show system info`); in SCM
the device `name` is the serial and the `id` equals it.

**Other live findings:** SCM rejects `All` as a parent folder (use `ngfw-shared`) and
raw port names at folder level (use `$variable` names + `default_value`); see
[Phase B2](#phase-b2--scm-configuration).
