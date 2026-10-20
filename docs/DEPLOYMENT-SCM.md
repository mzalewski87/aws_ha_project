# Deployment Guide — Path B: Strata Cloud Manager

> **STATUS (2026-10-20): LIVE-VERIFIED on a fresh AWS account in TWO regions (eu-central-1 +
> eu-west-1) behind Global Accelerator, including (for Region A) a full teardown and a second
> deployment from the repository code alone.**
>
> Verified live:
> - VM-Series on PAN-OS 12.2.3 with the Advanced Routing Engine onboard to SCM. The folder
>   configuration (logical router, interfaces, zones, NAT, policy) applies in one pass and is
>   pushed to and committed on both firewalls.
> - Active/Passive HA is configured from SCM, and the pair was upgraded in place to 12.2.4
>   through SCM.
> - A forced failover moves the public EIP and the floating IPs. It also moves the TGW
>   inspection routes (`ReplaceRoute`), seen in CloudTrail, once the trust ENI carries a
>   floating IP; see [HA failover](#ha-failover-what-moves-and-why).
> - GlobalProtect, built locally on both units: a client connected and reached the DC. The
>   certificate is Let's Encrypt.
> - Guacamole: TOTP is enforced and there is no default account from the first boot.
> - The two-tier AD CS PKI.
> - Advanced IP Defense in list mode (`alert` and `block`).
> - The admin/test panel: AD login, policy simulation, failover tests with timings.
>
> - Region B: second pair onboarded into the SAME SCM folder with per-device region overrides,
>   HA from SCM, GP gateway `gw-b`, portal listing both gateways on all four units, a replica DC
>   (AD replication 0 failures both ways), Global Accelerator health-checking both regions'
>   portals, and the panel showing and testing both regions.
>
> **Not covered:**
> - A live region-outage run (the panel's *Region outage* test exists; run it to measure).
> - GP session behaviour *during* a failover (only the state after it was checked).
> - SSL decryption (its script uses Panorama).
> - The root CA's CRL in AD (see [PKI](#pki-notes)).
> - Frontier Virtual Patching (licence/version prerequisites only; it cannot be triggered on
>   demand).
>
> Path A (Panorama, [DEPLOYMENT.md](DEPLOYMENT.md)) is unchanged.

Path B is the same AWS deployment as path A: VPCs, TGW, a VM-Series Active/Passive HA pair,
GlobalProtect, DC + PKI, and Guacamole. The difference is that **Strata Cloud Manager**
replaces Panorama as the management plane. Select it with `management_mode = "scm"`.

## What changes vs path A

| Concern | Path A (Panorama) | Path B (SCM) |
|---|---|---|
| Management plane | Panorama EC2 + EBS log disk | SCM tenant (no EC2) |
| Bootstrap init-cfg | `panorama-server=<ip>`, `vm-auth-key`, `tplname`, `dgname` | `panorama-server=cloud` + registration PIN |
| Activation | manual serial + licence + device cert (OTP) on Panorama | none — the device-certificate PIN is in the firewall's init-cfg |
| Config container | template stack + device group | one SCM **folder** |
| Per-device values | template variables + raw-XML override script | `scm_variable` with `device =` (native) |
| Config workspace | `phase2-panorama-config/` (`panos` provider) | `phase2-scm-config/` (`scm` provider) |
| Registration | `register-fw-panorama.sh` | `scm-onboard-fw.sh` |
| Commit / push | `configure-panorama.sh commit` | `scm-push.sh` (waits for every firewall's local commit) |
| HA | `configure-ha.sh` (SSH per firewall) | `scm-ha.sh` (SCM `/ha-configurations`) |
| Version rule | Panorama >= firewall PAN-OS | none; path B runs the newest PAN-OS SCM supports |
| Routing engine | legacy virtual router | **ARE** — `scm_logical_router`; init-cfg `plugin-op-commands=advance-routing:enable` |
| Logging | Panorama log collector | Strata Logging Service (tenant side) |
| Jump host | inside `modules/panorama` | `modules/ssm_jumphost` |
| GP portal/gateway | `panos` resources + one raw-XML node | device-local XML on **each** unit (`scm-gp-local.sh`) |

---

## Deployment procedure (fresh AWS account)

Commands run from the repository root unless noted. Values in `<...>` are yours. Secrets
(auth code, PIN, SCM client secret, passwords) belong in an **untracked** env file that you
`source`; never in a tracked file or a commit.

### B0 — Prerequisites (once per account / tenant)

1. **AWS**
   - Credentials for the target account (SSO: `aws sso login`, refresh before long runs; an
     expired token makes a long apply fail late).
   - Subscribe to the **VM-Series BYOL** Marketplace product (`scripts/accept-marketplace-terms.sh`
     prints the link; the Panorama product is not needed).
   - An EC2 key pair, or set `ssh_public_key` and let Terraform create one.
2. **Licensing**
   - A Software NGFW **deployment profile** with enough credits: 2 firewalls per region, and
     every redeploy consumes activations again.
   - **Activate the profile against the SCM tenant (TSG) the firewalls will join, before they
     boot.** Without this, the firewalls license and fetch a device certificate but never get an
     SCM endpoint (see [Troubleshooting](#troubleshooting)).
3. **SCM**
   - The tenant's **TSG ID**.
   - A **service account** (client ID + secret) that can edit configuration and push.
   - Export the following variables in your untracked env file:
     ```bash
     export SCM_TSG_ID=<tsg id> SCM_CLIENT_ID=<sa>@<tsg>.iam.panserviceaccount.com
     export SCM_CLIENT_SECRET=<secret> TF_VAR_scm_client_secret="$SCM_CLIENT_SECRET"
     ```
4. **Registration PIN**: generate a device-certificate registration PIN (ID + value) in the
   Customer Support Portal. It expires, so generate it shortly before step B1.
5. **Domain** (needed for Let's Encrypt, Guacamole and the panel): a domain you control where you
   can delegate a subdomain (NS records) to Route53.

### B1 — Root variables

Copy `terraform.tfvars.example` to `terraform.tfvars` and set at least:

```hcl
management_mode   = "scm"
vmseries_version  = "12.2.3"   # newest Marketplace image SCM lists; 11.1.x fails SCM's bootstrap push
key_name          = "<key pair>"            # or ssh_public_key = "ssh-ed25519 ..."

fw_auth_code              = "<BYOL auth code>"   # secrets: prefer TF_VAR_* from your env file
fw_registration_pin_id    = "<PIN id>"
fw_registration_pin_value = "<PIN value>"

dc_promote_to_dc         = true
dc_ad_test_user_name     = "admin"
dc_ad_test_user_password = "<strong password>"   # becomes a Domain Admin; used by the PKI scripts
dc_safe_mode_password    = "<strong password>"

enable_custom_domain             = true
custom_domain_subdomain_zone     = "<lab.example.com>"
custom_domain_cert_mode          = "letsencrypt"
custom_domain_letsencrypt_email  = "<you@example.com>"
custom_domain_letsencrypt_staging = true          # flip to false once everything works (5 certs/week limit)

enable_guacamole = true          # https://rdp.<zone>/guacamole/
enable_panel     = true          # https://panel.<zone>/   (path B only)
# panel_enable_failover   = true                  # lets panel operators stop/start the firewalls
# panel_alb_ingress_cidrs = ["<your public IP>/32"]
```

A plan refuses to run when `management_mode = "scm"` is set without the registration PIN.

### B2 — Networking, jump host, firewalls

```bash
terraform init
M=module.region_a.module
terraform apply -target=$M.vpc_security -target=$M.vpc_mgmt -target=$M.vpc_spoke1 \
                -target=$M.vpc_spoke2 -target=$M.transit_gateway -target=$M.bootstrap \
                -target=$M.ssm_jumphost
terraform apply -target=$M.firewall -target=$M.loadbalancer -target=$M.routing -target=$M.spoke1_app
```

The firewalls boot, license, fetch their device certificate with the PIN and appear in the
tenant as *Available Devices*, usually 10–20 minutes after launch.

### B3 — DNS delegation and certificate

```bash
terraform apply -target='module.custom_domain[0].aws_route53_zone.sub[0]'
terraform output custom_domain_name_servers     # create these NS records at the parent zone
dig +norecurse @<parent zone NS> NS <lab.example.com>   # check the delegation at the parent
terraform apply -target=module.custom_domain    # Let's Encrypt wildcard via DNS-01
```

### B4 — SCM folder, onboarding, HA, push

```bash
source <your env file>
terraform -chdir=phase2-scm-config init
cp phase2-scm-config/terraform.tfvars.example phase2-scm-config/terraform.tfvars   # tsg id, client id
terraform -chdir=phase2-scm-config apply -parallelism=4     # 1) folder, defaults, interfaces, router, zones, NAT, policy

# 2) wait for both firewalls, move them into the folder, write fw_devices.auto.tfvars.json.
#    Keys may be the management IPs (root output fw_mgmt_private_ips) or the serials.
bash scripts/scm-onboard-fw.sh AWS-HA-Transit \
  10.10.0.11=10.10.20.11/24,10.10.10.11/24 \
  10.10.0.12=10.10.20.12/24,10.10.10.12/24

terraform -chdir=phase2-scm-config apply -parallelism=4     # 3) per-device overrides

# 4) HA configs (stored in SCM), then ONE push carries everything, then check
J=phase2-scm-config/fw_devices.auto.tfvars.json
PRIMARY_SERIAL=$(jq -r '.fw_devices|to_entries[]|select(.value.trust_ip=="10.10.20.11/24")|.key' $J) \
SECONDARY_SERIAL=$(jq -r '.fw_devices|to_entries[]|select(.value.trust_ip=="10.10.20.12/24")|.key' $J) \
PRIMARY_MGMT_IP=10.10.0.11 SECONDARY_MGMT_IP=10.10.0.12 \
PRIMARY_HA2_IP=10.10.30.11 SECONDARY_HA2_IP=10.10.30.12 \
  bash scripts/scm-ha.sh
bash scripts/scm-push.sh AWS-HA-Transit
bash scripts/scm-verify.sh AWS-HA-Transit     # expect one active + one passive, our rules before deny-all
```

The addresses above are the defaults (`security_vpc_cidr = 10.10.0.0/16`). For other CIDRs, read
them from `terraform output fw_mgmt_private_ips` and `fw_ha2_private_ips`.

### B5 — Everything else (DC, PKI hosts, Guacamole, panel)

**Only after B4.** The spokes reach the internet through the firewalls, and until those carry NAT
and policy the DC's SSM agent cannot come online.

```bash
terraform apply        # DC (promoted to panw.labs), CA hosts, Guacamole, panel, ACM certificates
```

### B6 — PKI chain

```bash
export AWS_REGION=<region> DOMAIN=panw.labs DOMAIN_ADMIN=admin DOMAIN_PASSWORD=<dc_ad_test_user_password>
export ROOT_CA_ID=$(terraform output -raw pki_root_ca_instance_id)
export SUB_CA_ID=$(terraform output -raw pki_sub_ca_instance_id)
aws ec2 start-instances --instance-ids "$ROOT_CA_ID"     # needed on a re-run: the script stops the root at the end
bash scripts/setup-pki.sh
DC_INSTANCE_ID=$(terraform output -raw dc_instance_id) bash scripts/setup-machine-autoenroll.sh
```

### B7 — GlobalProtect (on EACH unit)

```bash
# env: SCM_*, GPAPI_PASSWORD (temporary admin), GP_USER_PASSWORD (test user gpuser),
#      KEY_FILE (SSH private key of the firewalls)
export JUMP_INSTANCE_ID=$(terraform output -raw ssm_jumphost_instance_id)
export GW_FQDN=gw-a.<zone> CERT_CN=gp.<zone>
for ip in 10.10.0.11 10.10.0.12; do
  for mode in admin build letsencrypt cleanup; do FW_IP=$ip bash scripts/scm-gp-local.sh $mode; done
done
```

- `admin` creates a temporary superuser (`gpapi`) over SSH.
- `build` writes the certificate placeholder, TLS profile, local auth, tunnel node, gateway and
  portal.
- `letsencrypt` installs the real certificate.
- `cleanup` deletes `gpapi` again.

A `FAILED` or exit code 142 after `admin`/`cleanup` is the SSH session timer. The firewall's own
`Configuration committed successfully` line is the real result.

### B8 — Panel (if `enable_panel`)

```bash
terraform -chdir=phase2-scm-config apply -parallelism=4   # rule panel-ldap-to-dc (already there after B4 with defaults)
bash scripts/scm-push.sh AWS-HA-Transit

# AD groups: panel-admins (sign in) + panel-operators (failover tests). AD accounts only.
AWS_REGION=<region> DC_INSTANCE_ID=$(terraform output -raw dc_instance_id) \
  PANEL_USERS="admin" PANEL_OPERATORS="admin" bash scripts/panel-setup.sh ad

# Firewall account panelro (role panel-ro) on both units; needs an existing superuser
# (e.g. gpapi: run scm-gp-local.sh admin on each unit first, cleanup afterwards).
AWS_REGION=<region> JUMP_INSTANCE_ID=$(terraform output -raw ssm_jumphost_instance_id) \
  PANEL_SECRET_ARN=$(terraform output -raw panel_secret_arn) FW_IPS="10.10.0.11 10.10.0.12" \
  FW_ADMIN_USER=gpapi FW_ADMIN_PASSWORD="$GPAPI_PASSWORD" bash scripts/panel-setup.sh fw
```

### B9 — Optional: Advanced IP Defense

Set `ip_defense_mode = "alert"` (or `"block"`) in `phase2-scm-config/terraform.tfvars`, then
apply and push:

```bash
terraform -chdir=phase2-scm-config apply -parallelism=4
bash scripts/scm-push.sh AWS-HA-Transit
```

### B10 — Optional: Region B + Global Accelerator (multi-region)

The second region uses the same `region_stack` (`eu-west-1`, CIDRs `10.2x.0.0/16`). Its
firewalls join the **same SCM folder**. Only the region-specific values (floating IP and
gateways) are overridden per device.

1. Set the root `terraform.tfvars`:
   ```hcl
   enable_region_b = true
   region_b        = "eu-west-1"
   ```
   Then apply in two passes. The cross-region resources iterate over Region B route tables,
   which do not exist yet. `IncorrectState` / `InvalidTransitGatewayID.NotFound` on the first
   pass is AWS eventual consistency: re-run.
   ```bash
   terraform apply -target=module.region_b
   ```
2. Set `enable_global_accelerator = true` and apply everything: TGW peering, cross-region routes,
   GA, `gw-b`, and the panel's Region B pair.
   ```bash
   terraform apply
   ```
3. Run the SCM workspace with `gp_local_ips = ["10.10.10.100", "10.20.10.100"]` in
   `phase2-scm-config/terraform.tfvars`:
   ```bash
   bash scripts/scm-onboard-fw.sh AWS-HA-Transit \
     10.20.0.11=10.20.20.11/24,10.20.10.11/24,10.20.10.100/32,10.20.20.1,10.20.10.1 \
     10.20.0.12=10.20.20.12/24,10.20.10.12/24,10.20.10.100/32,10.20.20.1,10.20.10.1
   terraform -chdir=phase2-scm-config apply -parallelism=4
   PRIMARY_SERIAL=... SECONDARY_SERIAL=... PRIMARY_MGMT_IP=10.20.0.11 SECONDARY_MGMT_IP=10.20.0.12 \
     PRIMARY_HA2_IP=10.20.30.11 SECONDARY_HA2_IP=10.20.30.12 bash scripts/scm-ha.sh
   bash scripts/scm-push.sh AWS-HA-Transit      # pushes to all four units; waits for every one
   ```
   - The onboarding keeps the Region A entries in `fw_devices.auto.tfvars.json` and adds Region
     B's.
   - The Region B firewalls' first boot took about 35 minutes before they connected.
4. Set `region_b_create_dc = true` and run `terraform apply` **after** step 3, because the DC
   needs the Region B firewalls for egress. It joins `panw.labs` as an additional DC; promotion
   takes 25–40 min. Check on either DC: `repadmin /replsummary` shows 0 fails. DC↔DC traffic
   uses TGW peering directly, not the firewalls.
5. Build GlobalProtect on EACH Region B unit, then rebuild the portal on the Region A units so
   that **every** portal lists both gateways:
   - common settings: `GATEWAYS="gw-a.<zone>:1 gw-b.<zone>:1"`;
   - Region B units: `GW_FQDN=gw-b.<zone> GW_NAME=gp-gateway-eu-west FLOATING=10.20.10.100/32
     IP_POOL=10.20.200.0/24 DNS_SERVER_PRIMARY=10.23.0.10 DNS_SERVER_SECONDARY=10.13.0.10`
     (`admin`, `build`, `letsencrypt`);
   - Region A units: `build` again with `GATEWAYS` and `DNS_SERVER_SECONDARY=10.23.0.10` (the
     Let's Encrypt certificate is kept);
   - finally run `cleanup` on all four units.
6. Create `panelro` on the Region B units: `FW_IPS="10.20.0.11 10.20.0.12" ... panel-setup.sh fw`.
7. Verify:
   - `aws globalaccelerator list-endpoint-groups` (API region `us-west-2`) shows both regions
     `HEALTHY`;
   - `https://gw-b.<zone>/global-protect/prelogin.esp` answers with a trusted certificate;
   - the panel topology shows both pairs.

On an active unit, every Frontier Virtual Patching content download (every few minutes on
12.2.4) is followed by an HA-Sync job of about 2 minutes. Config writes during it fail with
"A commit is pending". `scm-gp-local.sh` waits it out.

### Verification checklist

| Check | How | Expected |
|---|---|---|
| SCM sees the pair | `bash scripts/scm-verify.sh AWS-HA-Transit` | both connected, one `active` + one `passive`, our rules above `deny-all` |
| Portal | `curl -s https://gp.<zone>/global-protect/prelogin.esp` | `<status>Success</status>`, trusted certificate |
| GP client | connect a GlobalProtect client to `gp.<zone>` as `gpuser` | tunnel up, DC reachable, DNS suffix set |
| Guacamole | `https://rdp.<zone>/guacamole/` | login + TOTP enrolment, RDP to the DC |
| Panel | `https://panel.<zone>/` | AD login; Status shows both units; Policy simulation answers |
| HA moves everything | panel → Failover tests → *HA failover* | EIP **and** routes follow the active unit (topology), portal outage a few seconds |

---

## HA failover: what moves, and why

The PAN-OS AWS HA plugin (secondary-IP mode, live on PAN-OS 12.2.4, plugin 6.2.1) runs on the
unit that becomes active. On takeover it moves the **secondary IPs** of the failed unit's
dataplane ENIs to its own ENIs; the EIP follows the untrust floating IP. It also rewrites
**the route-table entries that point at those ENIs** (`ReplaceRoute`).

An ENI **without** a secondary IP is left alone. With the floating IP on the untrust ENI only,
the EIP followed every failover, but the TGW inspection routes (`0.0.0.0/0` → trust ENI)
stayed on the now-passive unit. The portal was up, but every east-west and spoke flow was
black-holed: the panel's LDAP login, RDP via Guacamole, GP users to the DC, and spoke egress.
The panel's live topology made it visible (EIP on fw2, routes on fw1).

**Fix:** fw1's trust ENI carries a floating secondary IP as well (`<trust subnet>.100`). PANW's
guide asks for this too: "add a secondary IP address to your dataplane interfaces on the first
(to be active) HA peer". The `aws_route` to the trust ENI ignores `network_interface_id`, because
the plugin owns it at runtime and Terraform used to point it back at fw1. The route is replaced
only when fw1's trust ENI itself is recreated.

**Verified in CloudTrail:**
- With the trust IP in place, a soft failover made the new active unit call
  `AssignPrivateIpAddresses` (both floating IPs) and `ReplaceRoute` (both TGW-attachment route
  tables), about 6 s after the suspend. The failback moved them back.
- Before the fix, a failback moved only the untrust IP and made no `ReplaceRoute` call.

**Existing deployments** created before this change need the secondary IP added once to the
trust ENI the routes point at, because `private_ips` is in `ignore_changes`:

```bash
aws ec2 assign-private-ip-addresses --network-interface-id <route-target trust ENI> \
  --private-ip-addresses <trust subnet>.100 --allow-reassignment
```

Other HA facts:
- HA1 needs TCP 28769/28260 **and** ICMP between the mgmt IPs.
- Preemption is off (PANW guidance for AWS), so after a failover the roles stay swapped until a
  failback (the panel's *Align the pair*).
- `running-sync` can read `not synchronized` for a while after an SCM push and then recover by
  itself. The panel waits 90 s before it forces `sync-to-remote`. On SCM-managed units that was
  checked live not to overwrite the peer's own interface addresses, which come from SCM
  per-device variables.

## Routing: ARE (logical routers), not the legacy virtual router

SCM-managed firewalls report `advanced_routing: true`. SCM's own **bootstrap push**
(`NGFW-Bootstrap-Push`) is also rejected when interfaces are not in a logical router
(`Interface ethernet1/2 has no logical-router configured`), which is what a legacy virtual router
created over REST produced on the first attempt. The router is `scm_logical_router`: one
`default` VRF with the four interfaces and two static routes whose next hops are folder
variables. init-cfg turns ARE on from the first boot.

## Firmware and in-place upgrades

The firewalls launch on the newest PAN-OS that is both in the Marketplace for VM-Series BYOL and
listed by SCM (`GET /config/device/v1/software-versions`). That was 12.2.3 at the time of
writing.

An older release (11.1.15) failed SCM's bootstrap push: a tenant DLP data profile references an
application (`general-browsing`) that release does not know. Changing `vmseries_version`
recreates the firewalls, which means:
- BYOL activations are consumed again;
- the firewalls get new serials;
- `scm-onboard-fw.sh`, the overrides apply and `scm-ha.sh` must be re-run;
- the old devices must be deactivated in the Customer Support Portal.

`scripts/scm-upgrade.sh <folder> <version>` upgrades in place through an SCM upgrade rule and
schedule. It was run live from 12.2.3 to 12.2.4, and the GP portal kept its Let's Encrypt
certificate. The live API differs from the OpenAPI document in ways that each cost a failed run:
- Dates are `YYYY/MM/DD`. Dashes are rejected as `invalid date` for every value.
- `job_type` must be `download-install-reboot`. If it is omitted the schedule is accepted, but
  nothing happens at the start time.
- Start times are read as **UTC**.
- `GET /software-upgrade-status` stays empty during a real upgrade. Completion is judged by the
  devices: target version, connected, and every pair active/passive.
- Both units rebooted within a few seconds of each other despite `ha_orchestration`. Plan it as
  a short outage.
- The script refuses to start unless every firewall of the folder is connected, and it always
  removes its schedule.

## What the `scm` provider cannot do (and what covers it)

| Needed | Why not Terraform | Covered by |
|---|---|---|
| HA (incl. HA2 on `ethernet1/1`) | no HA resource; `ethernet_interface` has no `ha` mode | `scripts/scm-ha.sh` (REST) |
| GP portal + gateway (+ tunnel node, pool, DNS) | **SCM exposes no NGFW portal/gateway object** | device-local XML API — `scripts/scm-gp-local.sh` |
| Moving devices out of a folder | not in the provider | `scripts/scm-folder-release.sh` (teardown) |

Prisma Access Agent was evaluated and rejected: its API (`MobileAgent`) belongs to Prisma Access
(cloud), so it cannot replace GlobalProtect on our own VM-Series.

## GlobalProtect notes

**Run every mode on EACH unit.** Local configuration (the GP objects *and* the temporary `gpapi`
admin) is **not replicated** between SCM-managed peers. The local commit warns "...not currently
synchronized to the HA peer, therefore this commit will only be applied to the local device".
When GP was built only on the active unit, a forced failover left the portal dead (`HTTP 000`).

Local config **survives SCM pushes**.

**Certificate.** A self-signed certificate whose subject equals its issuer must be a CA, and a CA
certificate carries only `keyUsage = Certificate Sign`. Browsers then refuse it
(`ERR_SSL_KEY_USAGE_INCOMPATIBLE`). So `build` creates a placeholder, and `letsencrypt` installs
the wildcard from `module.custom_domain`. One wildcard covers the portal and every gateway.
`build` keeps `gp-le` if it is already present: an earlier version re-pointed the TLS profile at
the placeholder and silently broke a trusted portal.

**Let's Encrypt staging → production** needs a new ACME account, and the staging objects cannot
be refreshed against production ("No account exists with the provided key"). The steps are:
1. `terraform state rm` the `acme_registration` and `acme_certificate`.
2. Set `custom_domain_letsencrypt_staging = false`.
3. Apply `module.custom_domain`.
4. Run `letsencrypt` on each unit.

**Multi-gateway portal.** `GATEWAYS="gw-a.<zone>:1 gw-b.<zone>:2"` lists several external
gateways (FQDN and priority) on the portal. An IP would go in `<ip>`, not `<fqdn>`.

**DNS for clients.** The gateway pushes `DNS_SERVER_PRIMARY` (default the DC, `10.13.0.10`), an
optional `DNS_SERVER_SECONDARY` and `DNS_SUFFIX` (default `panw.labs`). The VPC resolver cannot
see the AD zone. Verified: the client shows the suffix and the DC as its DNS server, and
`nslookup panw.labs` returns the DC. An actual domain join over the VPN was not tested.

**Commit gotchas (each failed a real commit):**
- The portal requires `custom-login-page`, `custom-home-page` and `custom-help-page`
  (`factory-default`).
- The TLS `max-version` must be `tls1-2` (`max` is rejected).
- "A commit is pending" means retry after the running commit.
- The job result is the first non-empty `<result>`.
- `dns-server` takes `<member>` children.
- The client IP pool must be in exactly one place (`remote-user-tunnel-configs`).

## PKI notes

Terraform creates the two CA hosts. `scripts/setup-pki.sh` builds the chain and
`scripts/setup-machine-autoenroll.sh` sets the autoenrollment policy; both use only SSM
RunCommand and both ran live on path B. Fixed along the way:

- **The issuing CA can end up outside the domain.** Its user-data retries the join for about
  20 minutes and gives up. `setup-pki.sh` now checks membership and joins the host itself. The
  symptom was a misleading "user name or password is incorrect" from
  `Install-AdcsCertificationAuthority`.
- **Publishing the root into AD silently did nothing** when it ran as SYSTEM. It now runs as a
  domain admin and the script verifies the AD container.

Known gap: `certutil -dspublish` of the **root CRL** fails with `ERROR_DS_REFERRAL`, because the
root is a standalone, non-domain CA. The chain and the issuing CA work, but revocation checking
of the root by clients is not covered.

RunCommand keeps the command text, including the domain-admin password, in SSM history for its
retention period. Use a lab-only account and rotate it afterwards.

## Guacamole (both paths)

- An internet-facing ALB (ACM certificate) leads to the Guacamole host in the mgmt VPC, which
  opens RDP to the DC **through the firewalls** over the TGW. No RDP port is exposed.
- The admin password is generated into Secrets Manager (`terraform output
  guacamole_admin_secret_arn`). The default `guacadmin` account is removed before the container
  is reachable, and **TOTP is mandatory**.
- If TOTP is not enforced or `guacadmin` still exists, the bootstrap stops the container (fails
  closed).
- The ALB is open to the internet by default (`alb_ingress_cidrs`); narrowing it is the cheapest
  hardening.
- The host's PostgreSQL lives on the instance. The AMI is pinned at first creation
  (`ignore_changes = [ami]`), so a new AL2023 release does not replace it.
- On the firewalls, rule `guacamole-rdp-to-dc` (`trust→trust`, `ms-rdp`) is placed ahead of
  `deny-all`.

## Optional run C — Advanced IP Defense, Frontier Virtual Patching, admin panel

### Advanced IP Defense — list-based variant (`ip_defense_mode = off | alert | block`)

PANW publishes the IP-reputation categories as **predefined external dynamic lists**
(`panw-aipd-*`, `panw-torexit-ip-list`, `panw-bulletproof-ip-list`, `panw-highrisk-ip-list`).
Every SCM folder inherits them, so nothing is created in the tenant.

`phase2-scm-config` puts the rules at the top of the pre-rulebase:
- `alert`: outbound `allow` + log. It opens nothing and blocks nothing; a hit is visible by rule
  name in the traffic log.
- `block`: outbound `deny`, plus an inbound `deny` for the listed sources.

Verified live:
- A firewall expands a list into addresses (`panw-aipd-c2-infra-ip-list`: 5500 entries, type
  `predefined-ip`).
- `test security-policy-match` shows a listed address hitting `ipdef-outbound-alert` /
  `ipdef-outbound-block`, while an ordinary address hits `spokes-outbound`. No traffic is sent.

The profile-based delivery (attached to a zone, cloud lookup, 12.2.3+) has no object in the SCM
API or provider.

Gotcha: **a new SCM rule is appended at the BOTTOM** of the rulebase. `relative_position = "top"`
only works when the rule is created, so an existing rule has to be recreated.

### Frontier Virtual Patching

It needs the Advanced Threat Prevention Plus licence and **PAN-OS 12.2.4+**, which is why the
pair was upgraded in place. It is a Vulnerability Protection profile setting. Its pre-disclosure
signatures **cannot be triggered on demand**, and PANW documents no test method.

### Admin panel (`modules/panel`, path B only)

A web console on its own ALB (`https://panel.<zone>/`), with two hosts in two AZs of the mgmt VPC.
It sits outside the firewall path it reports on, so it stays up through firewall and AZ failures.

**Login.** NTLM bind to the DC plus membership of `panel-admins` (viewer) or also
`panel-operators` (operator). Groups are matched by DN (`CN=...,CN=Users,<base>`).
- Sessions use secure, HttpOnly, SameSite=Strict cookies, with an absolute 8 h lifetime.
- Forms carry CSRF tokens.
- Login is rate-limited per client IP and per user.
- Every action is a JSON line in `journalctl -u panel`.

**Status.** HA state, version and sync of both units.

**Policy simulation.** It asks the **active** unit which rule a session would hit
(`test security-policy-match`), so no traffic is sent.
- The result is animated: the rulebase (`show running security-policy`) is walked top to bottom,
  showing why each earlier rule was skipped and which rule matched.
- The packet is shown delivered or dropped, with a "why" list.
- It can load a sample address from a predefined IP list, as a destination (outbound) or as a
  source (inbound).

**Failover tests.** Operators only, and only with `panel_enable_failover = true`. The page shows
a live topology: HA roles, EC2 state, sync, priority, which unit holds the EIP and which the
routes point at, and whether the portal answers.

| Test | What it does | Typical |
|---|---|---|
| Check and repair sync | waits for `running-sync`, forces `sync-to-remote` only as a last resort | seconds |
| HA failover | suspend the active unit, wait for the takeover, restore it, fail back | ~1–2 min |
| Hard failover | stop the active unit's EC2 instance, takeover, start it, wait until it is passive and synchronized, fail back | ~7–9 min (PAN-OS boot) |
| Align the pair | make the preferred primary (lowest HA priority) active again | ~1 min |
| Recover | start stopped units, clear `suspended`, wait for a clean pair | varies |

- Measured live: takeover 0.7–7.7 s, and the portal was unreachable for about 5 s per
  switchover (the AWS IP move).
- Every run is stored in DynamoDB (`<prefix>-panel-runs`), with its phases, timeline, portal
  outages (probed every second until the portal is back) and history.

Guard rails:
- a typed confirmation;
- a sign-in within the last hour for operators;
- **one test at a time across both hosts** (a conditional DynamoDB lease, renewed by a
  heartbeat);
- refusal to start unless the pair is a clean active/passive pair;
- a timeout on every wait;
- **a disruptive step is undone if its wait fails** (suspend → functional, stop → start);
- the IAM role can stop/start the two firewall instances and nothing else in EC2.

The firewall account (`panelro`, role `panel-ro`) can run XML-API **operational** commands only.
That includes HA suspend and also restart, so treat panel operator access like firewall admin
access. A plain `superreader` cannot run `test`/`request`/`show` through the XML API ("User not
authorized to perform this operation").

Known limits:
- The AD bind is NTLM over plain LDAP (the DC has no LDAPS certificate yet).
- A host replaced *during* a test interrupts it. The run shows as "interrupted"; use *Recover*.
- Region failure needs Region B.

---

## Teardown

Reverse order, one workspace at a time:

1. **SCM:**
   ```bash
   bash scripts/scm-folder-release.sh AWS-HA-Transit
   terraform -chdir=phase2-scm-config destroy -parallelism=4
   ```
   SCM refuses to delete a folder with devices in it, and its API cannot delete devices. Zones are
   deleted only after the rules that name them (`depends_on`); otherwise SCM answers 409.
2. **AWS:** refresh the SSO session, then run `terraform destroy` in the root.
3. **Licences:** deactivate the firewalls' serials in the Customer Support Portal. This removes
   them from SCM and frees the credits.

What a teardown leaves or changes:
- **Route53 zone.** It is destroyed, so a redeploy gets **new name servers**. Update the parent
  delegation and verify it against the parent's authoritative server
  (`dig +norecurse @<parent ns> NS <zone>`), not a caching resolver; resolvers cache the old NS
  for about a day.
- **Let's Encrypt production** allows 5 identical certificates a week. Use staging while
  iterating.
- **EBS volumes.** The firewall module sets `delete_on_termination = true` (the Marketplace
  default keeps the root volume). After a destroy, list unattached EBS volumes anyway.

## Troubleshooting

**Firewalls never appear in SCM (`GET /config/setup/v1/devices` returns `[]`).** On the firewall
CLI (SSH via the SSM jump host), run `show cloud-management-status`:

| Output | Meaning |
|---|---|
| `Endpoint:` **empty**, `Connected: no` | The serial is not associated with a tenant: the deployment profile was not activated for this TSG (B0). Licence and device certificate can look perfectly healthy — that is the trap. |
| Endpoint set, DNS/TCP/SSL failing | Network: outbound HTTPS/DNS from the mgmt subnet (NAT, route, SG egress). |

Once the profile is activated, the devices appear within minutes without a reboot.

**Endpoint still empty although the profile lists the new serials.** First confirm egress works:
`show log system direction equal backward | match cloud` shows a `gRPC connection ... established`
line. After reusing licence slots, SCM took tens of minutes to list the new serials. Deactivating
a device in the Customer Support Portal removes it from SCM.

**`scm-onboard-fw.sh` waits forever.** A management-IP key matches only a **connected** device.
Stale entries of replaced firewalls (same IP, disconnected) are ignored on purpose.

**Hostname is `ip-10-10-0-11`, not `fw1`.** DHCP overrides the init-cfg hostname. Identify devices
by serial or management IP. In SCM the device `name` is the serial.

**DC never shows up in SSM / `create-ad-test-user` times out.** B5 ran before B4: the spokes have
no egress until the firewalls carry NAT and policy.

**East-west traffic dead after a failover, portal fine.** The routes did not follow. Check the
panel topology or `describe-route-tables`, and see [HA failover](#ha-failover-what-moves-and-why).

**Other live findings:**
- SCM rejects `All` as a parent folder; use `ngfw-shared`.
- SCM rejects raw port names at folder level; use `$variable` names + `default_value`.
- A push's parent job finishes immediately. The firewalls commit in **child** jobs, and
  `scm-push.sh` waits for every connected unit.
