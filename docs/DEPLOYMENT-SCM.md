# Deployment Guide — Path B: Strata Cloud Manager

> **STATUS (2026-10-21): LIVE-VERIFIED on a fresh AWS account in TWO regions (eu-central-1 +
> eu-west-1) behind Global Accelerator, including (for Region A) a full teardown and a second
> deployment from the repository code alone, and (for Region B) a rebuild of both firewalls.
> All four units run PAN-OS 12.2.4.**
>
> Verified live:
> - VM-Series (Marketplace image 12.2.3, upgraded in place to 12.2.4) with the Advanced Routing
>   Engine onboard to SCM. The folder
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
> - The admin/test panel: AD login, policy simulation, failover tests with timings, both regions.
> - AWS WAF on the panel and the HTTPS test website (`website.<zone>`, CloudFront): geo allow-list,
>   rate limit, managed rules (a SQLi probe gets 403); the NLB is reachable only from CloudFront.
> - Region B: second pair onboarded into the SAME SCM folder with per-device region overrides,
>   HA from SCM, GP gateway `gw-b`, portal listing both gateways on all four units, a replica DC
>   (AD replication 0 failures both ways), Global Accelerator health-checking both regions'
>   portals, and the panel showing and testing both regions.
>
> **Not covered:**
> - A region-outage run with the current Global Accelerator health-check threshold of 1. The one
>   live run (threshold 3) measured a 73 s portal outage; re-run the panel's *Region outage* test
>   to measure the improvement.
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
vmseries_version  = "12.2.3"   # newest Marketplace image SCM lists (11.1.x fails SCM's bootstrap push);
                               # upgraded to the mandatory 12.2.4 in B4b
key_name          = "<key pair name>"
ssh_public_key    = "ssh-ed25519 AAAA..."   # with key_name: Terraform imports the key in EVERY region
                                            # (key pairs are per region; Region B needs it too)

fw_auth_code              = "<BYOL auth code>"   # secrets: prefer TF_VAR_* from your env file
fw_registration_pin_id    = "<PIN id>"
fw_registration_pin_value = "<PIN value>"

dc_promote_to_dc         = true
dc_ad_test_user_name     = "admin"
dc_ad_test_user_password = "<strong password>"   # becomes a Domain Admin; used by the PKI scripts
dc_safe_mode_password    = "<strong password>"

enable_custom_domain              = true
custom_domain_subdomain_zone      = "<lab.example.com>"
custom_domain_cert_mode           = "letsencrypt"
custom_domain_letsencrypt_email   = "<you@example.com>"
custom_domain_letsencrypt_staging = true          # flip to false once everything works (5 certs/week limit)

enable_guacamole      = true     # https://rdp.<zone>/guacamole/
guac_ldap_enabled     = true     # AD accounts in group guacusers sign in to Guacamole (B8)
enable_panel          = true     # https://panel.<zone>/   (path B only)
panel_enable_failover = true     # panel operators may stop/start the firewalls (failover tests)
web_app_hostname      = "website"   # https://website.<zone>: test site via CloudFront + ACM + WAF
waf_allowed_countries = ["PL"]   # WAF geo allow-list for panel + website — must include YOUR country
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
tenant as *Available Devices*, usually 10–35 minutes after launch.

If a firewall never appears, check its system log for `NOV-021 Insufficient credits`. The BYOL
credit pool is empty, and every deploy or rebuild consumes activations. Deactivate old serials in
the Customer Support Portal, then recreate the instances.

### B3 — DNS delegation and certificate

```bash
terraform apply -target='module.custom_domain[0].aws_route53_zone.sub[0]'
terraform output custom_domain_name_servers     # create these NS records at the parent zone
dig +norecurse @<parent zone NS> NS <lab.example.com>   # check the delegation at the parent
terraform apply -target=module.custom_domain    # Let's Encrypt wildcard via DNS-01
```

### B4 — SCM folder, onboarding, HA, push

Keep `ip_defense_mode = "off"` in `phase2-scm-config/terraform.tfvars` for now (see B9).

```bash
source <your env file>                    # SCM_TSG_ID, SCM_CLIENT_ID, SCM_CLIENT_SECRET, TF_VAR_scm_client_secret
terraform -chdir=phase2-scm-config init
cp phase2-scm-config/terraform.tfvars.example phase2-scm-config/terraform.tfvars   # tsg id, client id
terraform -chdir=phase2-scm-config apply -parallelism=4     # 1) folder, defaults, interfaces, router, zones, NAT, policy

# 2) wait for both firewalls, move them into the folder, write fw_devices.auto.tfvars.json.
#    Keys: the management IPs (root output fw_mgmt_private_ips) or the serials.
WAIT_MINUTES=45 bash scripts/scm-onboard-fw.sh AWS-HA-Transit \
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

### B4b — Upgrade to PAN-OS 12.2.4 (mandatory)

The deployment requires **PAN-OS 12.2.4 or later**. Frontier Virtual Patching needs it, and every
pair must run the same release. The newest VM-Series BYOL Marketplace image is 12.2.3, so the
firewalls are upgraded in place right after B4:

```bash
bash scripts/scm-upgrade.sh AWS-HA-Transit 12.2.4
```

- The script upgrades only the units of the folder that are not on 12.2.4 yet. The others are
  excluded in the upgrade rule (`exclude_devices`), and the script refuses to schedule if SCM did
  not store the exclusion.
- It refuses to start while any device of the folder is disconnected.
- Both units of a pair reboot within seconds of each other. Expect a few minutes of outage for
  that region.
- Check with `scm-verify.sh` (or the panel's Status page): 12.2.4 on every unit.

### B5 — Everything else (DC, PKI hosts, Guacamole, panel)

**Only after B4.** The spokes reach the internet through the firewalls, and until those carry NAT
and policy the DC's SSM agent cannot come online.

```bash
terraform apply        # DC (promoted to panw.labs), CA hosts, Guacamole, panel, website, WAF, ACM
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

Environment, for every `scm-gp-local.sh` mode:

```bash
source <your env file>   # SCM_TSG_ID SCM_CLIENT_ID SCM_CLIENT_SECRET
                         # GPAPI_PASSWORD (temporary admin) GP_USER_PASSWORD (test user gpuser)
export KEY_FILE=<SSH private key of the firewalls>
export JUMP_INSTANCE_ID=$(terraform output -raw ssm_jumphost_instance_id)
export GW_FQDN=gw-a.<zone> CERT_CN=gp.<zone>
for ip in 10.10.0.11 10.10.0.12; do
  for mode in admin build letsencrypt; do FW_IP=$ip bash scripts/scm-gp-local.sh $mode; done
done
```

What each mode does:
- `admin` creates a temporary superuser (`gpapi`) over SSH.
- `build` writes the certificate placeholder, TLS profile, local auth, tunnel node, gateway and
  portal.
- `letsencrypt` installs the real certificate. Run it right after `build`: until then the unit
  serves the placeholder certificate.
- `cleanup` deletes `gpapi`. Run it **after B8 and B9**, which still need `gpapi`.

On an active unit, every Frontier Virtual Patching content download (every few minutes) triggers
an HA-Sync of about 2 minutes. Config writes during it fail with "A commit is pending".
`build` waits it out.

A message such as "commit job N … was still running when the session ended" (after `admin` or
`cleanup`) means the commit outlived the SSH session. Check it with `show jobs id N`; it usually
ends OK.

### B8 — AD access: Guacamole (if `guac_ldap_enabled`) and panel (if `enable_panel`)

```bash
# Guacamole: rule guacamole-ldap-to-dc is created by B4 (default guac_ldap_source_cidrs).
# Group guacusers + bind account svc-guacamole (password from the Guacamole secret).
AWS_REGION=<region> DC_INSTANCE_ID=$(terraform output -raw dc_instance_id) \
  GUAC_SECRET_ARN=$(terraform output -raw guacamole_admin_secret_arn) \
  GUAC_USERS="admin" bash scripts/guacamole-ldap-setup.sh
```

Panel:

```bash
# Rule panel-ldap-to-dc is created by B4 with the default panel_source_cidrs.
# AD groups: panel-admins (sign in) + panel-operators (failover tests). AD accounts only.
AWS_REGION=<region> DC_INSTANCE_ID=$(terraform output -raw dc_instance_id) \
  PANEL_USERS="admin" PANEL_OPERATORS="admin" bash scripts/panel-setup.sh ad

# Firewall account panelro (role panel-ro) on every unit, created through gpapi (still there from B7).
AWS_REGION=<region> JUMP_INSTANCE_ID=$(terraform output -raw ssm_jumphost_instance_id) \
  PANEL_SECRET_ARN=$(terraform output -raw panel_secret_arn) FW_IPS="10.10.0.11 10.10.0.12" \
  FW_ADMIN_USER=gpapi FW_ADMIN_PASSWORD="$GPAPI_PASSWORD" bash scripts/panel-setup.sh fw
```

### B9 — Optional: Advanced IP Defense

The rules use PANW's predefined IP lists (`panw-aipd-*`), which ship with the **threat content
package**. A freshly booted firewall has none (`No valid threat content package exists`), and a
push that contains the rules is rejected by every such unit (`Unknown address
'panw-aipd-scanning-ip-list'`, seen live on a rebuilt Region B pair).

1. Install content on **each** unit first (same environment as B7; `gpapi` must exist):
   ```bash
   for ip in 10.10.0.11 10.10.0.12; do FW_IP=$ip bash scripts/scm-gp-local.sh content; done
   ```
   It downloads and installs the latest Apps+Threats and Antivirus and polls every job.
2. Set `ip_defense_mode = "alert"` (or `"block"`) in `phase2-scm-config/terraform.tfvars`, then
   apply and push:
   ```bash
   terraform -chdir=phase2-scm-config apply -parallelism=4
   bash scripts/scm-push.sh AWS-HA-Transit
   ```
3. Remove the temporary admin from every unit:
   ```bash
   for ip in 10.10.0.11 10.10.0.12; do FW_IP=$ip bash scripts/scm-gp-local.sh cleanup; done
   ```

The rule mechanics are explained [below](#advanced-ip-defense--list-based-variant-ip_defense_mode--off--alert--block).

### B10 — Optional: Region B + Global Accelerator (multi-region)

The second region uses the same `region_stack` (`eu-west-1`, CIDRs `10.2x.0.0/16`). Its
firewalls join the **same SCM folder**; only the region-specific values (floating IP and
gateways) are overridden per device. Steps, in order:

1. **Region B infrastructure.** Set `enable_region_b = true` and `region_b = "eu-west-1"` in the
   root `terraform.tfvars`, then apply Region B alone first. The cross-region resources iterate
   over Region B route tables, which do not exist yet. `IncorrectState` or
   `InvalidTransitGatewayID.NotFound` on the first pass is AWS eventual consistency; re-run.
   ```bash
   terraform apply -target=module.region_b
   ```
2. **Peering and Global Accelerator.** Set `enable_global_accelerator = true` and apply
   everything: TGW peering, cross-region routes, GA, `gw-b` and the panel's Region B pair.
   ```bash
   terraform apply
   ```
   Re-run once if the peering was not `available` yet (`IncorrectState`).
3. **Onboard the Region B pair.** Add `"10.20.10.100"` to `gp_local_ips` in
   `phase2-scm-config/terraform.tfvars`. Region B's first boot took about 35 minutes.
   ```bash
   WAIT_MINUTES=60 bash scripts/scm-onboard-fw.sh AWS-HA-Transit \
     10.20.0.11=10.20.20.11/24,10.20.10.11/24,10.20.10.100/32,10.20.20.1,10.20.10.1 \
     10.20.0.12=10.20.20.12/24,10.20.10.12/24,10.20.10.100/32,10.20.20.1,10.20.10.1
   terraform -chdir=phase2-scm-config apply -parallelism=4
   ```
   The three extra fields are the floating IP and the two gateways. The onboarding keeps the
   Region A entries in `fw_devices.auto.tfvars.json`.
4. **Content, if IP Defense is on (B9).** Fresh units have no threat content, so run `admin` and
   `content` on `10.20.0.11` and `10.20.0.12` before the push.
5. **HA and push** to all four units:
   ```bash
   J=phase2-scm-config/fw_devices.auto.tfvars.json
   PRIMARY_SERIAL=$(jq -r '.fw_devices|to_entries[]|select(.value.trust_ip=="10.20.20.11/24")|.key' $J) \
   SECONDARY_SERIAL=$(jq -r '.fw_devices|to_entries[]|select(.value.trust_ip=="10.20.20.12/24")|.key' $J) \
   PRIMARY_MGMT_IP=10.20.0.11 SECONDARY_MGMT_IP=10.20.0.12 \
   PRIMARY_HA2_IP=10.20.30.11 SECONDARY_HA2_IP=10.20.30.12 bash scripts/scm-ha.sh
   bash scripts/scm-push.sh AWS-HA-Transit      # waits for every connected unit
   ```
6. **Upgrade the Region B pair** to 12.2.4. The Region A pair is excluded automatically.
   ```bash
   bash scripts/scm-upgrade.sh AWS-HA-Transit 12.2.4
   ```
7. **Region B DC.** Set `region_b_create_dc = true` and run `terraform apply`. It needs the
   Region B firewalls for egress. It joins `panw.labs` as an additional DC; promotion takes
   25–40 min. Check on either DC: `repadmin /replsummary` shows 0 fails. DC↔DC traffic uses TGW
   peering directly, not the firewalls.
8. **GlobalProtect.** Every portal lists both gateways, `GATEWAYS="gw-a.<zone>:1 gw-b.<zone>:1"`.
   Equal priority lets each client pick the best-responding gateway; use `:1` / `:2` to prefer
   one.
   - Region B units (`admin` if not done yet, then `build` and `letsencrypt`):
     ```bash
     GW_FQDN=gw-b.<zone> GW_NAME=gp-gateway-eu-west FLOATING=10.20.10.100/32 \
     IP_POOL=10.20.200.0/24 DNS_SERVER_PRIMARY=10.23.0.10 DNS_SERVER_SECONDARY=10.13.0.10
     ```
     Global Accelerator starts sending Region B traffic as soon as port 443 answers, so run
     `build` and `letsencrypt` back to back.
   - Region A units: run `admin` and `build` again with `GATEWAYS` and
     `DNS_SERVER_SECONDARY=10.23.0.10`. The Let's Encrypt certificate is kept.
9. **Panel account on Region B:**
   `FW_IPS="10.20.0.11 10.20.0.12" ... panel-setup.sh fw`. Then run `cleanup` on all four units.
10. **Verify:**
    - `aws globalaccelerator list-endpoint-groups --region us-west-2 --listener-arn …` shows
      both regions `HEALTHY`;
    - `https://gw-b.<zone>/global-protect/prelogin.esp` answers with a trusted certificate;
    - the panel topology shows both pairs;
    - a panel *HA failover* on Region B moves EIP and routes both ways.

### Verification checklist

| Check | How | Expected |
|---|---|---|
| SCM sees the pair(s) | `bash scripts/scm-verify.sh AWS-HA-Transit` | all units connected on 12.2.4, one `active` + one `passive` per pair, our rules above `deny-all` |
| Portal | `curl -s https://gp.<zone>/global-protect/prelogin.esp` | `<status>Success</status>`, trusted certificate |
| GP client | connect a GlobalProtect client to `gp.<zone>` as `gpuser` | tunnel up, DC reachable, DNS suffix set |
| Guacamole | `https://rdp.<zone>/guacamole/` | login + TOTP enrolment, RDP to the DC |
| Panel | `https://panel.<zone>/` | AD login; Status shows every unit; Policy simulation answers |
| HA moves everything | panel → Failover tests → *HA failover* (each region) | EIP **and** routes follow the active unit, both ways; portal outage a few seconds |
| Website + WAF | `curl -s -o /dev/null -w '%{http_code}' https://website.<zone>/` and a probe like `?id=1' OR '1'='1` | `200`; the probe `403` |
| No path around CloudFront | `curl -m 8 http://<app NLB DNS name>/` | times out |
| Global Accelerator | `aws globalaccelerator list-endpoint-groups --region us-west-2 --listener-arn <443 listener>` | every region `HEALTHY` |
| Firewall ENIs | primary of each `fw1-untrust` / `fw1-trust` ENI (see [HA failover](#ha-failover-what-moves-and-why)) | the unit's own `.11`, never the floating `.100` (a plan postcondition also checks it) |

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

**The floating IP must be a SECONDARY address (found live, Region B).** The plugin maps the
failed unit's primary address to the peer's primary, and moves secondaries. The module used to
pass the ENI addresses as an unordered set, so AWS sometimes made the **floating .100 the
primary** of fw1's ENI ("10.20.10.100" sorts before "10.20.10.11"). The next failover then
moved fw1's own `.11` and put the EIP on fw2's own `.12`: portal and gateway dead, and GA marked
the region unhealthy.

The module now passes an **ordered** list (`private_ip_list`, first = primary) for fresh
deployments. Check an existing deployment; on fw1's untrust and trust ENIs the floating `.100`
must NOT be the primary:

```bash
aws ec2 describe-network-interfaces --filters "Name=tag:Name,Values=<prefix>-fw1-untrust,<prefix>-fw1-trust" \
  --query 'NetworkInterfaces[].[TagSet[?Key==`Name`]|[0].Value, PrivateIpAddresses[?Primary].PrivateIpAddress|[0]]' --output text
```

A primary cannot be changed in place. Recreate the affected pair's firewalls, which costs new
serials and BYOL activations, then onboard, set up HA, upgrade and build GP again (B10 steps 3–9).
For Region B:

```bash
F='module.region_b[0].module.firewall'
R=""; for n in fw1-mgmt fw1-ha2 fw1-trust fw1-untrust fw2-mgmt fw2-ha2 fw2-trust fw2-untrust; do
  R="$R -replace=$F.aws_network_interface.fw[\"$n\"]"; done
terraform apply $R -replace="$F.aws_instance.fw[\"fw1\"]" -replace="$F.aws_instance.fw[\"fw2\"]" \
  -target=$F -target='module.region_b[0].module.routing'
terraform apply        # afterwards: panel, cross-region routes
bash scripts/scm-folder-release.sh AWS-HA-Transit ngfw-shared <old serial 1> <old serial 2>
```

Done live for Region B. Two lessons from it:
- Replace **all eight ENIs and both instances**, and limit `-target` to
  `module.region_b[0].module.firewall` and `module.region_b[0].module.routing`. The panel hosts
  are `create_before_destroy` and depend on these ENIs. With the panel in the same run, Terraform
  forces the ENIs into create-before-destroy too and fails with `InvalidIPAddress.InUse`, after it
  has already removed the TGW route. Apply the panel afterwards.
- Drop the old serials from `phase2-scm-config/fw_devices.auto.tfvars.json` before onboarding the
  new ones. Move the old (disconnected) devices out of the folder and deactivate them in the
  Customer Support Portal.

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

**The minimum supported release of this deployment is 12.2.4** (Frontier Virtual Patching, and
one release on every unit). Until the Marketplace offers a 12.2.4 image, every fresh or rebuilt
pair is upgraded in place right after onboarding (B4b, B10 step 6).

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

**Multi-gateway portal.** `GATEWAYS="gw-a.<zone>:1 gw-b.<zone>:1"` lists several external
gateways (FQDN and priority) on the portal. With equal priorities the client uses the
best-responding gateway (*best available*); give one gateway a lower number to prefer it. An IP
would go in `<ip>`, not `<fqdn>`.

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

## WAF, the test website and what stays outside WAF

`enable_waf` (default on) puts **AWS WAF** in front of the two public **web** endpoints
(`waf.tf`, `modules/waf`):

| Endpoint | WAF scope | Attached to |
|---|---|---|
| `https://panel.<zone>/` | REGIONAL (Region A) | the panel ALB |
| `https://website.<zone>/` (`web_app_hostname`) | CLOUDFRONT (us-east-1) | the CloudFront distribution |

Rules, in order:
1. `geo-allow-only` blocks every source country not in `waf_allowed_countries` (lab: `["PL"]`;
   default empty = no geo rule). **Include your own country**, or you lock yourself out of the
   panel.
2. A per-IP rate limit per 5 minutes: `waf_panel_rate_limit` 1000 (the panel's failover page
   polls, about 150 requests per 5 min per open tab) and `waf_website_rate_limit` 2000.
3. AWS managed groups: IP reputation, anonymous IPs (VPN/Tor), known bad inputs (Log4j and
   friends), the core rule set, and SQLi. The anonymous-IP group's `HostingProviderIPList` rule is
   set to **count**: it would block every visitor coming from a cloud provider, including your own
   tests from EC2.

Blocks show up in CloudWatch metrics and as WAF sampled requests per rule.

**Website.** CloudFront (ACM certificate in us-east-1, auto-renewing) → app NLB → firewall DNAT →
Apache in spoke 1, so the firewalls still inspect it. The NLB has a security group that admits
only **CloudFront's origin-facing prefix list** (`app_nlb_cloudfront_only`, default on), so the
site cannot be reached around CloudFront and its WAF. Turning this on for an existing deployment
replaces the NLB; CloudFront follows the new name in the same apply.

**Outside WAF, by design:**
- GlobalProtect (`gp.<zone>` via Global Accelerator, `gw-a`/`gw-b` on the firewall EIPs). WAF
  only fronts HTTP(S) on ALB, CloudFront and API Gateway, and GP clients must reach the firewalls
  directly.
- `http://gp.<zone>` (port 80 through GA to the firewall EIP) still reaches the test page without
  TLS or WAF. Use `https://website.<zone>`.
- Guacamole's ALB can take the same module (`modules/waf`, scope REGIONAL) if wanted.

## Global Accelerator: how traffic really flows

Both endpoint groups have a 100 % traffic dial. That is **not** a 50/50 split and there is no
"primary" region. GA sends each client to the **nearest healthy** region, measured from the
client's GA edge location. Clients in Poland land in eu-central-1 (Region A). Clients nearer to
Ireland land in eu-west-1. If a region's endpoint fails its health check, all of its clients move
to the other region.

The panel shows exactly this: the region serving clients near the panel is *serving (nearest)*,
the other healthy region *standby*, and an unhealthy one *not serving*. It reads endpoint health
from the GA API, cached 15 s.

An active/standby design would set Region B's traffic dial to 0 % and raise it on failure, which
needs automation (GA does not move traffic to a 0 % group by itself). The proximity behaviour
fits GlobalProtect better: users near each region use it, and each region backs up the other.

**Failover time.** GA health checks run every 10 s, the shortest interval GA allows. With the
default threshold of 3, a region outage left the portal unreachable for **73 s** in the panel's
region test. The threshold is now **1** (`health_check_threshold` in `modules/global_accelerator`).
Detection takes about 10 s, and the rest is GA propagation plus the firewalls going down. The
price is that a single lost health check also moves traffic.

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

### Optional: sign-in with AD accounts (`guac_ldap_enabled`)

Members of one AD group (default `guacusers`) can sign in with their domain account. TOTP stays
mandatory: on first sign-in each user enrols a code. Nobody is added in Guacamole by hand. The
bootstrap creates a Guacamole user group with the same name as the AD group and gives it the DC
connection. Guacamole matches AD groups to its own groups by name, so adding someone to the AD
group is all it takes.

1. Root `terraform.tfvars`: `guac_ldap_enabled = true` (optionally `guac_ldap_group`). This
   **replaces the Guacamole host** when toggled on an existing deployment. The new host starts
   with a new database, so the admin and everyone else enrol TOTP again (the admin password stays
   the same).
2. Firewall rule `guacamole-ldap-to-dc` (`trust→trust`, `ldap`, Guacamole subnet → DC). Path B
   creates it by default (`guac_ldap_source_cidrs` in `phase2-scm-config`). Path A needs
   `guac_ldap_source_cidrs = ["10.11.20.0/23"]` in `phase2-panorama-config`, then apply and
   commit-all.
3. Group and bind account on the DC (re-run after every host replacement, because the bind password
   is regenerated with the host's secret):

   ```bash
   AWS_REGION=<region> DC_INSTANCE_ID=$(terraform output -raw dc_instance_id) \
     GUAC_SECRET_ARN=$(terraform output -raw guacamole_admin_secret_arn) \
     GUAC_USERS="admin" bash scripts/guacamole-ldap-setup.sh
   ```

   The bind account (`svc-guacamole`) is a plain domain user, used only to look accounts up.
   Its password is the `ldap_bind_password` that Terraform generated into the Guacamole secret.

Notes:
- **Who can sign in** is decided by the LDAP search filter (direct or nested membership of
  `CN=<group>,CN=Users,<base>`). An AD account outside the group gets "invalid credentials".
  **What a user sees** comes from the Guacamole group of the same name.
- It uses plain LDAP on 389, like the panel login: the DC has no LDAPS certificate yet. The bind
  crosses only the TGW and the firewalls.
- Group membership is read at every sign-in, so removing someone from the AD group takes effect
  on their next sign-in. Their Guacamole account (only the TOTP key) stays until an admin
  deletes it.
- The settings were live-verified on 2026-10-21 on Guacamole 1.6.0: extensions ldap, postgresql
  and totp loaded, AD user signed in with TOTP and opened RDP to the DC. That test reconfigured the
  running container by hand. The bootstrap block in `user-data.sh.tpl` applies the same
  settings, but it first runs on the next host replacement.

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
| HA failover | suspend the active unit, wait for the takeover, restore it, fail back | ~1 min (measured 47 s) |
| Hard failover | stop the active unit's EC2 instance, takeover, start it, wait until it is passive and synchronized, fail back | ~9 min (measured ~7.5 min; PAN-OS boot) |
| Region outage | stop BOTH units of a region (portal moves to the other region via GA), observe 30 s, start them, wait for a clean pair, fail back | ~10 min (measured 8.5 min with a 60 s observation) |

The "typical" durations the panel shows are the measured times plus 30 %, rounded down to whole
minutes. A region test starts only when the other region's pair is clean and Global Accelerator
reports it healthy, so clients always have somewhere to go.
| Align the pair | make the preferred primary (lowest HA priority) active again | ~1 min |
| Recover | start stopped units, clear `suspended`, wait for a clean pair | varies |

- Measured live: takeover 0.7–7.7 s, and the portal was unreachable for about 5 s per
  switchover (the AWS IP move).
- Every run is stored in DynamoDB (`<prefix>-panel-runs`), with its phases, timeline, portal
  outages (probed every second until the portal is back) and history.

**Topology.** The panel learns which pairs exist (instance ids, regions, management IPs) and
the Global Accelerator ARN from the SSM parameter `/panel/<prefix>/topology`, which Terraform
writes. The hosts re-read it every 60 s, so adding Region B or rebuilding firewalls never
replaces the panel hosts (they used to be recreated whenever an instance id changed, which forced
create-before-destroy on the firewall ENIs). SSM refuses parameter names that start with `aws` or
`ssm`, hence the `/panel/` prefix.

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
- The region test needs Region B and Global Accelerator.

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
Stale entries of replaced firewalls (same IP, disconnected) are ignored on purpose. After a
rebuild, if SCM is slow to list the new units, pass their serials as keys instead.

**Push rejected with `Unknown address 'panw-aipd-…'`.** The unit has no threat content yet (fresh
boot or rebuild) and IP Defense is on. Run `admin` + `content` on it (B9), then push again.

**`A commit is pending` from `scm-gp-local.sh`.** The active unit is HA-syncing after a content
download (about 2 minutes, every few minutes with Frontier Virtual Patching). The script retries;
if it gives up, run the mode again.

**Firewall never appears and the system log shows `NOV-021 Insufficient credits`.** The BYOL
credit pool is empty; deactivate old serials in the Customer Support Portal, then recreate the
instances (`-replace` on `aws_instance.fw`).

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
