# Deployment Guide — AWS VM-Series HA + Multi-Region GlobalProtect

End-to-end runbook. The deployment is split into phases because the `panos`
provider connects to Panorama on every plan, so Panorama config lives in a
separate workspace from the base infrastructure.

> **Before you start:**
> 1. **[docs/PREREQUISITES.md](PREREQUISITES.md)** — install the tools (Terraform,
>    AWS CLI v2 + Session Manager plugin, …) and log in to AWS from the CLI.
> 2. **[docs/CONFIGURATION.md](CONFIGURATION.md)** — exactly which parameter goes
>    in which file and where to source each value.
>
> 🔌 **How do I connect to the DC (RDP) / Panorama / firewalls?** →
> **[docs/ACCESS.md](ACCESS.md)** — one place with every remote-access command.
>
> **Where to run this:** this repo is the **source of truth**. Run `terraform
> apply` from a **separate clone** with AWS credentials — not from the source
> tree. `terraform validate` / `fmt -check` are the only Terraform commands run
> in the source repo.

**Contents:** [Architecture](#architecture) · **[Accessing the environment](ACCESS.md)** · [Prerequisites](#phase-0--prerequisites)
· [Phase 1a](#phase-1a--base-networking--panorama) · [Phase 2a](#phase-2a--panorama-config-panos-workspace)
· [Phase 1b](#phase-1b--firewalls--app--routing) · [Phase 2b](#phase-2b--register-firewalls-on-panorama)
· [Phase 3](#phase-3--windows-dc) · [Phase GP](#phase-gp--globalprotect) ·
[Phase R2](#phase-r2--region-b--global-accelerator) · [Optional EKS](#optional--eks--wordpress--edl)
· [Access](ACCESS.md) · [Verification](#verification) ·
[Traffic tests](#testing-traffic-flows) · [HA/failover](#ha--failover) ·
[Teardown](#teardown) · [Troubleshooting](#troubleshooting) · [Variables](#key-variables)

---

## Architecture

Two building blocks per region — a **security VPC** running a VM-Series
**Active/Passive HA pair**, and a **management VPC** with Panorama — joined by a
**Transit Gateway** (appliance mode). GlobalProtect Portal + Gateway terminate on
the FW public EIP; **Global Accelerator** fronts the portal across regions.

```mermaid
flowchart TB
    clients["GlobalProtect clients / App users"]
    ga["AWS Global Accelerator<br/>(anycast) — GP Portal"]
    cf["CloudFront — App"]
    clients --> ga
    clients --> cf

    subgraph RA["Region A (primary — hosts Panorama)"]
      direction TB
      subgraph RAsec["Security VPC"]
        fw1a["VM-Series FW1 (active)"] <-->|"HA1 + HA2"| fw2a["VM-Series FW2 (passive)"]
      end
      pano["Mgmt VPC: Panorama + SSM jump host"]
      appa["Spoke1: App (Apache)"]
      dca["Spoke2: AD Domain Controller"]
      tgwa["Transit Gateway (appliance mode)"]
      RAsec <--> tgwa
      pano <--> tgwa
      tgwa <--> appa
      tgwa <--> dca
    end

    subgraph RB["Region B (secondary)"]
      direction TB
      subgraph RBsec["Security VPC"]
        fw1b["VM-Series FW1 (active)"] <-->|"HA1 + HA2"| fw2b["VM-Series FW2 (passive)"]
      end
      dcb["Spoke2: replica AD DC"]
      tgwb["Transit Gateway"]
      RBsec <--> tgwb
      tgwb <--> dcb
    end

    ga --> RAsec
    ga -. "region failover" .-> RBsec
    cf --> appa
    tgwa <-. "cross-region peering" .-> tgwb
    dca <-. "AD replication" .-> dcb
    pano -. "manages both regions" .-> RBsec
```

Text fallback (same topology, for terminals without Mermaid rendering):

```
                  AWS Global Accelerator (anycast, portal FQDN)
                     │                                  │
        ┌────────────┴─────────────┐        ┌───────────┴──────────────┐
        │ REGION A (hosts Panorama) │        │ REGION B (secondary)      │
        │ security VPC 10.10/16     │        │ security VPC 10.20/16     │
        │   FW1 active ⇅ FW2 passive │        │   FW1 active ⇅ FW2 passive │
        │   eth0 mgmt / e1/1 ha2     │        │   (managed by Region A    │
        │   e1/2 trust / e1/3 untrust│  TGW   │    Panorama via peering)   │
        │ mgmt VPC 10.11/16          │◀─peer─▶│                           │
        │   Panorama + SSM jump host │        │                           │
        │ spoke1 app, spoke2 AD DC   │        │ spoke2 replica AD DC      │
        └────────────┬──────────────┘        └────────────┬──────────────┘
                     │ Transit Gateway (appliance mode)    │
             spoke ↔ spoke / spoke ↔ internet inspected by the FWs
                                  AD replication ⇄ between the two DCs
```

**Failover behavior**

- **In-region (FW failure):** the passive firewall takes over; the PAN-OS AWS HA
  plugin moves the untrust floating IP, its Elastic IP, and the Transit Gateway
  inspection route to the peer.
- **Whole-region:** Global Accelerator health checks drop the failed region and
  steer the portal to the healthy one; GlobalProtect-native gateway failover
  moves VPN clients; GP AD/LDAP auth fails over to the surviving region's replica
  domain controller.

---

## Phase 0 — Prerequisites

Per AWS account, complete once before deploying:

1. **Subscribe to the BYOL AMIs** (one-time, per account, **console-only** — AWS
   has no CLI subscribe command). Verify with the helper:
   ```bash
   AWS_REGION=eu-central-1 bash scripts/accept-marketplace-terms.sh
   ```
   It prints the subscribe links and runs a **real** subscription check
   (`ec2 run-instances --dry-run`, not just AMI visibility — Marketplace AMIs
   are visible to everyone regardless of subscription, so `describe-images`
   would give a false "OK"). Look for `OK ... SUBSCRIBED`; `MISS ... NOT
   subscribed` means accept terms at the printed link and re-run.
2. **VM-Series auth code** with credit balance. Each deploy consumes BYOL
   credits from the pool, so keep a sufficient balance. Set `fw_auth_code`.
3. **Registration PIN** fresh (device-cert flow; PINs expire). Set
   `fw_registration_pin_id` / `fw_registration_pin_value`.
4. **Deployer IAM** with permissions for EC2/VPC/TGW/IAM/EKS/GA/CloudFront.
   Decide a state backend (S3 + DynamoDB lock) and configure it in
   `providers.tf` (`backend "s3"`), currently commented.
5. **EC2 key pair** in the target region(s) → set `key_name` (used for the
   Panorama admin SSH key and Windows password decryption).
6. Tools: `terraform >= 1.5`, `aws` CLI v2 with the **Session Manager plugin**,
   `curl`, `jq` optional; for the EKS add-on: `kubectl`, `helm`.

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in the REPLACE_ME values
```

---

## Phase 1a — Base networking + Panorama

Networking + Panorama + the SSM jump host (no FWs yet).

```bash
terraform init
terraform apply \
  -target=module.region_a.module.vpc_security \
  -target=module.region_a.module.vpc_mgmt \
  -target=module.region_a.module.vpc_spoke1 \
  -target=module.region_a.module.vpc_spoke2 \
  -target=module.region_a.module.transit_gateway \
  -target=module.region_a.module.bootstrap \
  -target=module.region_a.module.panorama
```

Panorama boots ~10–15 min. Grab the handoffs:

```bash
terraform output panorama_private_ip          # e.g. 10.11.0.10
terraform output ssm_jumphost_instance_id     # target for the SSM tunnel
```

---

## Phase 2a — Panorama config (panos workspace)

Panorama has no public IP and PAN-OS runs no SSM agent, so reach it through the
**SSM jump host**.

> **Admin password is set automatically in Phase 1a.** PAN-OS on AWS has no
> platform password injection (EC2 has no password field; Panorama on AWS has no
> bootstrap mechanism). So Phase 1a runs `scripts/set-panorama-password.sh` via
> a `terraform_data` provisioner: it SSHes to Panorama with the `key_name` key
> over the SSM tunnel and sets `panorama_admin_password`. **No manual step** — as
> long as `panorama_admin_password` is set in root `terraform.tfvars` and the
> private key is at `~/.ssh/<key_name>.pem` (or `ssh_private_key_file`). Set
> `phase2` `panorama_password` to the **same** value.
> (For manual troubleshooting only: `scripts/configure-panorama.sh ssh` opens a
> raw SSH port-forward to Panorama:22.)

> **Panorama activation (serial + device certificate) — plan the OTP timing.**
> Panorama ships with no serial/license/device-cert. phase2 activates it
> (`null_resource.panorama_activate` → `scripts/activate-panorama.sh`) from two
> tfvars:
> - `panorama_serial_number` — from CSP (register the Panorama auth code). Stable,
>   set it once. Enables `request license fetch`.
> - `panorama_device_otp` — CSP → Assets → Device Certificates → **Generate OTP**
>   for that serial. **Single-use, 60-minute TTL.** Panorama MUST get a device
>   certificate: a firewall that holds a device cert only connects to a Panorama
>   that also holds one — without it the FWs stay `Connected: no`.
>
> **Because the OTP expires in 60 min, generate it LAST, right before
> `terraform apply`** — not while you're still filling in the rest of tfvars. If
> `apply` is delayed or the OTP is reused, the fetch fails with "OTP is not
> valid"; just regenerate a fresh OTP and re-apply (the step re-runs when
> `panorama_device_otp` changes).

**Open the API tunnel** in one shell and keep it running:

```bash
bash scripts/configure-panorama.sh tunnel      # localhost:44300 -> Panorama:443
```

In a second shell, fill tfvars, then generate the OTP LAST and apply promptly:

```bash
cd phase2-panorama-config
cp terraform.tfvars.example terraform.tfvars
#  - panorama_password       = root panorama_admin_password
#  - panorama_serial_number  = "<your Panorama serial from CSP>"   (stable)
#  - template/device-group names must match root
#  >>> NOW generate a fresh OTP in CSP and paste it (60-min clock starts):
#  - panorama_device_otp     = "<fresh OTP>"
terraform init
terraform apply        # runs within the OTP's 60-min window
cd ..
```

What it does: waits for the API, **activates Panorama** (set serial → license
fetch → device-cert fetch via OTP), **generates the vm-auth-key** → writes
`../panorama_vm_auth_key.auto.tfvars` (auto-loaded by Phase 1b), pushes the
template / device group / interfaces / zones / single VR / static routes / NAT +
security policy, sets up the **log collector**, then commits + commit-all.

> `template_name` / `template_stack` / `device_group` here **must match** the
> root `panorama_template_stack` / `panorama_device_group` (FW init-cfg refs).

---

## Phase 1b — Firewalls + app + routing

The vm-auth-key from Phase 2a is auto-loaded — no manual editing.

```bash
terraform apply \
  -target=module.region_a.module.firewall \
  -target=module.region_a.module.loadbalancer \
  -target=module.region_a.module.routing \
  -target=module.region_a.module.cloudfront \
  -target=module.region_a.module.spoke1_app
```

FWs boot, activate the license with `fw_auth_code`, fetch the device cert with
the PIN, and register to Panorama with the vm-auth-key.

```bash
terraform output fw_mgmt_private_ips     # {"region_a":{"fw1":"10.10.0.11","fw2":"10.10.0.12"}}
terraform output fw_public_eips          # GP / portal / app entry
terraform output app_cloudfront_domain
```

---

## Phase 2b — Register firewalls on Panorama

Once the FWs register they appear as managed devices. Bind them to the device
group + template stack and push (tunnel from Phase 2a still up):

```bash
PANORAMA_PASSWORD=<pw> DEVICE_GROUP=AWS-Transit-DG TEMPLATE_STACK=AWS-Transit-Stack \
  bash scripts/register-fw-panorama.sh
```

Once both firewalls show `Connected: yes` and the Phase 2a interface config
(including the `ha2` interface) has been pushed, configure native HA — see
[Configuring native PAN-OS HA](#configuring-native-pan-os-ha) under
[HA & failover](#ha--failover).

> **Serial handoff for Phase GP.** The register script prints each firewall's
> PAN-OS serial (also visible in Panorama → Managed Devices, or via
> `<show><devices><connected>`). If you'll enable GlobalProtect, paste them into
> `phase2-panorama-config/terraform.tfvars` as `fw_serials` (keyed `fw1a`/`fw2a`
> /`fw1b`/`fw2b`) — phase2 uses them to push the **per-device untrust IP
> overrides** (each FW's static primary + the region floating IP, set by serial
> via the XML API) and to **activate the GP agent** per firewall. Left empty,
> both per-device steps are skipped — which is why GP binding/agent-download
> silently don't work until `fw_serials` is filled and phase2 re-applied.

---

## Phase 3 — Windows DC

Set `dc_promote_to_dc = true` (default) and `dc_safe_mode_password` in root
`terraform.tfvars`, then:

```bash
terraform apply -target=module.region_a.module.spoke2_dc
```

What happens: the instance boots, then user-data runs `Install-ADDSForest`
(installs AD DS + DNS, promotes a new forest) and **reboots** to finish. Total
time from `apply` to a working domain controller is typically **15–20
minutes** — most of it is the AD DS install + reboot, not the EC2 launch.

**Get the instance ID**, then **the Administrator password** (needs `key_name`
set — this decrypts the Windows-generated password, it's unrelated to
`dc_safe_mode_password`):

```bash
# from Terraform state (run in the root of your deploy clone):
terraform output -raw dc_instance_id
#   -> i-0123456789abcdef0
```

> **`Output "dc_instance_id" not found`?** `terraform output` only reads what's
> already in the state file — it doesn't compute anything fresh. If you pulled
> this repo's code (or any new output) after your last `apply`, the state
> doesn't have it yet. Fix with a no-op, safe refresh (creates/changes
> nothing, just recomputes outputs from what already exists):
> ```bash
> terraform apply -refresh-only -target=module.region_a.module.spoke2_dc
> ```
> **`-refresh-only` fixes ONLY the output problem above — it never creates or
> modifies real infrastructure.** If you pulled code that changes the DC
> itself (e.g. the IAM instance profile added for SSM access, below) and RDP
> then fails with `TargetNotConnected`, that's because `-refresh-only` can't
> attach it — you need a real `terraform apply -target=module.region_a.module.spoke2_dc`
> (safe: `iam_instance_profile` updates in place, no destroy/recreate).
> Confirm the fix landed with:
> `aws ec2 describe-instances --instance-ids <dc-id> --query 'Reservations[0].Instances[0].IamInstanceProfile'`
> (should not be `null`), then wait ~1–2 min for the already-running SSM Agent
> to register: `aws ssm describe-instance-information --filters
> "Key=InstanceIds,Values=<dc-id>" --query 'InstanceInformationList[0].PingStatus'`
> should read `Online` before RDP will work.

If you don't have the Terraform state handy at all, look the instance up
directly in AWS by its Name tag (`<name_prefix>-a-spoke2-dc`, e.g.
`awsha-a-spoke2-dc`):

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*-spoke2-dc" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

Either way, feed the instance ID straight in — no manual copy/paste needed:

```bash
aws ec2 get-password-data \
  --instance-id "$(terraform output -raw dc_instance_id)" \
  --priv-launch-key ~/.ssh/<key_name>.pem
```

> If this returns empty, the password isn't generated yet — EC2 needs a few
> minutes after launch before `get-password-data` has anything to return.

**Log in (RDP)** — full access guide in **[docs/ACCESS.md](ACCESS.md)**. The DC
has **no Bastion and no route from the mgmt VPC's jump host** (spoke2 is behind
the FW inspection path); instead it has its own SSM agent + IAM role (Windows
Server 2022's AMI ships with the agent preinstalled), so connect directly:

```bash
aws ssm start-session --target "$(terraform output -raw dc_instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3389"],"localPortNumber":["13389"]}'
# in another shell/RDP client: connect to localhost:13389, user Administrator
```

Keep the `start-session` command running while the RDP client is connected
(same pattern as the Panorama/FW tunnels, but this one talks directly to the
DC's own agent — no jump host in the path).

**Verify AD DS is actually up** (via the same SSM session, or a PowerShell
RunCommand): `Get-Service NTDS` should show `Running`, and `Get-ADDomain`
should return the domain (`dc_domain_name`, default `panw.labs`) without error.

> **If SSM never connects (`TargetNotConnected`) even 10+ minutes after
> `apply`:** `-InstallDns` makes the box authoritative for its own AD DNS
> zone and points its own DNS client at itself — a fresh AD-integrated zone
> has **no forwarders**, so it can't resolve public names at all, and the SSM
> Agent never attempts to connect (the block is on the host itself, before
> any packet reaches the network). The code handles this automatically (see
> `modules/spoke2_dc/main.tf`'s `<persist>true</persist>` user-data, which
> adds the VPC's own DNS resolver as a forwarder on the pass after promotion
> completes).

**AD test user for GP auth:** if `dc_ad_test_user_password` is set, Terraform
auto-creates an AD user (`dc_ad_test_user_name`, default `admin`) via SSM
RunCommand once the forest is confirmed up (`scripts/create-ad-test-user.sh`,
runs as part of the same `apply`). Verify with `Get-ADUser
<dc_ad_test_user_name>` over the same SSM session/RDP. This is the account
Phase GP's LDAP option (below) uses to bind — the same credentials also work
to actually log in to the GP portal for testing.

### Managing VPN users

GlobalProtect access is gated on the **`vpnusers` AD group** (`gp_vpn_group`,
default `vpnusers`). The same `apply` creates that group on the domain controller
and adds the test user to it, and Panorama is configured (LDAP group-mapping +
the GP auth-profile allow-list) so **only members of `vpnusers` can connect** —
in both regions (AD replication copies the group + members to the Region B
replica DC, and the shared Panorama template enforces the gate on both firewall
pairs). To let someone connect, create an AD user and add them to `vpnusers`; to
revoke, remove them from the group.

You can manage users **without RDP**, straight from your workstation, via SSM
RunCommand against the domain controller (`terraform output -raw dc_instance_id`):

```bash
DC=$(terraform output -raw dc_instance_id)
NEWUSER="alice"; NEWPASS='Ch00se-A-Strong-Passw0rd!'
aws ssm send-command --instance-ids "$DC" \
  --document-name AWS-RunPowerShellScript \
  --parameters commands="[\"New-ADUser -Name '$NEWUSER' -SamAccountName '$NEWUSER' -UserPrincipalName '$NEWUSER@panw.labs' -AccountPassword (ConvertTo-SecureString '$NEWPASS' -AsPlainText -Force) -Enabled \$true -PasswordNeverExpires \$true; Add-ADGroupMember -Identity 'vpnusers' -Members '$NEWUSER'\"]" \
  --query 'Command.CommandId' --output text
# check it: 
#   aws ssm send-command --instance-ids "$DC" --document-name AWS-RunPowerShellScript \
#     --parameters commands="[\"Get-ADGroupMember vpnusers | Select-Object -Expand SamAccountName\"]"
```

Or **over RDP** (see the SSM :3389 port-forward above), in a PowerShell prompt on
the DC:

```powershell
New-ADUser -Name alice -SamAccountName alice -UserPrincipalName alice@panw.labs `
  -AccountPassword (Read-Host -AsSecureString "Password") -Enabled $true -PasswordNeverExpires $true
Add-ADGroupMember -Identity vpnusers -Members alice
Get-ADGroupMember vpnusers        # verify
```

The new user logs in to GlobalProtect with the **bare sAMAccountName** (`alice`,
not `alice@panw.labs`) and their AD password, and reaches the AWS spoke resources
over the tunnel (split-tunnel `10.0.0.0/8`). A user who is NOT in `vpnusers`
authenticates against AD but is refused the VPN by the allow-list.

> **Group changes are not instant — allow ~1 minute.** The firewalls cache
> `vpnusers` membership and re-read it from AD on a schedule
> (`scripts/set-group-mapping.sh` sets the group-mapping `update-interval` to
> **60s**). So a user you just added can't connect until the next refresh — if
> they get `auth-failed` right after being added, wait ~a minute and retry. To
> pick it up **immediately**, force a refresh on the firewall (SSH via the jump
> host — see [ACCESS.md](ACCESS.md)):
> ```
> debug user-id refresh group-mapping all
> ```
> Verify what the firewall currently sees:
> ```
> show user group name "cn=vpnusers,cn=users,dc=panw,dc=labs"
> ```
> (This lists the members as `DOMAIN\user`, e.g. `panw\alice`. Once your user
> appears there, GlobalProtect login works.) The firewall that matters is the
> **active** one in the region the client connects to; a forced refresh targets
> the box you SSH to, whereas the 60s auto-refresh updates all of them.

---

## Phase GP — GlobalProtect

GlobalProtect provides a portal plus a tunnel-mode gateway, in single- and
multi-region deployments. See [GlobalProtect — how it's wired](#globalprotect--how-its-wired)
below for the implementation details.

GP objects live in the panos workspace, gated by `enable_globalprotect` (needs a
real server cert — public CA or an exported ACM cert; PAN-OS can't consume ACM
directly). See [Certificates for GlobalProtect](CONFIGURATION.md#certificates-for-globalprotect)
for exactly how to generate `gp_server_cert_pem`/`gp_server_key_pem` and where
each is consumed downstream. In `phase2-panorama-config/terraform.tfvars`:

```hcl
enable_globalprotect = true
gp_server_cert_pem   = "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----"
gp_server_key_pem    = "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
gp_external_gateways  = [
  { name = "gw-eu-central", address = "gw-eu-central.example.com", priority = "1" },
]

# Auth — pick ONE:
gp_local_users = { "vpnuser" = "<pw>" }   # gp_auth_method defaults to "local"
# --- OR, to authenticate against the AD DC instead (Phase 3 MUST be done first): ---
# gp_auth_method        = "ldap"
# gp_ldap_server_ip     = "<root output dc_private_ip>"
# gp_ldap_base_dn       = "DC=panw,DC=labs"        # from root dc_domain_name
# gp_ldap_bind_dn       = "admin@panw.labs"        # dc_ad_test_user_name @ dc_domain_name
# gp_ldap_bind_password = "<root dc_ad_test_user_password>"
```

`terraform apply` in the workspace. Point your GP portal FQDN at the Region A FW
public EIP (or at Global Accelerator once R2 is up). The agent picks the
best-available gateway and fails over natively across regions.

> **Two auth requirements to preserve:** the GP auth profiles must live at
> **vsys1** (not template-shared, or they can't see vsys1 users / the DC), and
> local users must be hashed with `openssl passwd -1` by
> `scripts/set-gp-local-users.sh` (the `panos_local_user` resource stores the
> password unhashed and is deliberately not used). Keep both as-is; changing
> either causes every login to return HTTP 512 / `auth-failed`. Details in
> [GlobalProtect — how it's wired](#globalprotect--how-its-wired).

> **GP app (agent) package must be activated on the firewalls.** The portal can
> only serve an installer that is **downloaded AND activated** on the hosting
> firewall — otherwise clicking "Download" in the portal returns a text file
> `errors.txt` saying "Could not find file" (PANW KB kA10g000000ClrhCAC). This is
> automated: `null_resource.gp_client_deploy` runs `scripts/deploy-gp-client.sh`,
> which drives check/download/activate on every firewall serial via Panorama's
> op-command proxy (version from `gp_client_version`, default `latest`). The
> firewalls need egress to the PANW update servers (already via NAT). It runs
> before the final commit; on a fresh deploy no manual step is needed. To run it
> standalone: `SERIALS="<s1> <s2> ..." PANORAMA_PASSWORD=... bash
> scripts/deploy-gp-client.sh`.

> **Client platform matters — match the CPU architecture.** The GlobalProtect
> app installs a **kernel-mode driver** (`gpfltdrv.sys`). **Windows on ARM cannot
> load an x64 kernel driver** (ARM64 Windows emulates x64 *user-mode* apps only),
> so the **x64 GP installer fails on a Windows-ARM machine**: the driver INF
> install returns `0xE000022F` / `Driver installation failed with error = 2`, the
> `PanGPS` service can't initialize, and the UI shows **"Connection Failed —
> Could not connect to the GlobalProtect service"** (`PanGPA.log`:
> `CPanSocket::onConnect ... error code = 10061`) — the portal is never even
> contacted. Test from a **native x64 (AMD64) Windows** client (a physical PC, an
> x64 Windows VM, or a Windows EC2 instance), or install the **native ARM64
> GlobalProtect app** (from the PANW support/CSP portal — the firewall portal
> serves the x64 build) on a Windows-ARM machine. macOS/Linux clients are also
> supported natively.

> **HTTP→HTTPS portal redirect (optional, `enable_http_redirect`).** The GP
> portal is HTTPS-only and PAN-OS has no built-in :80→:443 redirect for it;
> Global Accelerator is L4 (TCP/UDP) and cannot issue an HTTP 301. The AWS-native
> mechanism is an **ALB listener `redirect` action**, and GA supports an ALB as
> an endpoint. Setting `enable_http_redirect = true` (with
> `enable_global_accelerator = true`) creates a small, target-less redirect ALB
> per region (`modules/http_redirect_alb`, in the security VPC's public subnets)
> and points the GA **:80** listener at it, while **:443 + UDP 4501 still go
> straight to the firewall EIPs** (TLS terminates on the firewall — the ALB never
> touches real GP traffic). The 301 is host-preserving, so it works for any
> portal FQDN (`gp.<domain>`, the GA DNS name, even a bare IP). GP agents always
> dial HTTPS, so this is purely a browser convenience — off by default (adds one
> ALB per region, ~$16/mo each).

> **LDAP auth ordering matters:** the DC must already be promoted (Phase 3
> complete, `Get-ADDomain` working) before you set `gp_auth_method = "ldap"` —
> the LDAP profile is created either way, but a bind against a DC that isn't
> up yet just fails at commit/runtime, not at `plan`. The FW's LDAP bind also
> needs the `sec-spoke2-*` TGW route (added automatically, see
> `modules/region_stack/main.tf`) — if the bind times out, see
> [Troubleshooting](#troubleshooting).

### Custom domain (optional — branded, browser-trusted portal)

By default GP works on the raw firewall EIPs / Global Accelerator anycast IPs
with a **self-signed** cert (clients show a trust warning — fine for a lab).
For a real domain (e.g. `gp.lab.example.com`) with a **browser-trusted** cert,
turn on the optional `custom_domain` module. It creates a Route53 hosted zone
for a **delegated subdomain**, DNS records (portal → GA anycast, one gateway
record per region → that region's EIP), and — optionally — a **Let's Encrypt
wildcard cert via DNS-01** (no inbound reachability needed). Nothing is
hardcoded to a real domain; you supply every name as a variable.

It's a **two-step apply** because the subdomain NS delegation is a one-time
manual action at your parent domain, and the NS values only exist after the zone
is created:

```hcl
# root terraform.tfvars — step 1: create the zone, self-signed for now
enable_custom_domain          = true
custom_domain_subdomain_zone  = "lab.example.com"   # the subdomain you'll delegate
custom_domain_portal_hostname = "gp"                # -> gp.lab.example.com
custom_domain_cert_mode       = "self_signed"
```
```bash
terraform apply
terraform output custom_domain_name_servers   # 4 Route53 NS for the subdomain
```

**Delegate once:** at your parent domain's DNS (the registrar/zone for
`example.com`), create `NS` records for `lab` (the subdomain label) pointing at
those 4 name servers. Wait for propagation
(`dig NS lab.example.com +short` returns the Route53 NS).

```hcl
# root terraform.tfvars — step 2: issue the real cert
custom_domain_cert_mode           = "letsencrypt"
custom_domain_letsencrypt_email   = "you@example.com"
custom_domain_letsencrypt_staging = false          # true first if you want to dry-run
```
```bash
terraform apply
terraform output custom_domain_gateway_fqdns              # gw-a.lab..., gw-b.lab...
terraform output -raw custom_domain_cert_pem     > phase2-panorama-config/gp-cert.pem
terraform output -raw custom_domain_cert_key_pem > phase2-panorama-config/gp-key.pem
```

Then hand the cert + FQDNs to the panos workspace and re-apply it. `.tfvars`
can't call `file()` ("Functions may not be called here"), so paste the two PEMs
as heredocs:

```hcl
# phase2-panorama-config/terraform.tfvars
gp_server_cert_pem = <<-EOT
${file contents of gp-cert.pem — the whole chain, verbatim}
EOT
gp_server_key_pem = <<-EOT
${file contents of gp-key.pem — verbatim}
EOT
gp_external_gateways = [
  { name = "gw-eu-central", address = "gw-a.lab.example.com", priority = "1" },
  { name = "gw-eu-west",    address = "gw-b.lab.example.com", priority = "2" },
]
```

The wildcard `*.lab.example.com` covers the portal FQDN and every gateway FQDN
with one cert, so PAN-OS presents a trusted cert everywhere. The `gp.tf` regex
routes an FQDN `address` into PAN-OS's `<fqdn>` field automatically (a bare IP
goes into `<ip>`), so no other change is needed.

---

## Phase R2 — Region B + Global Accelerator

Region B is the same `region_stack` under the `aws.region_b` provider; its FWs
use the single Region A Panorama over cross-region TGW peering (`cross_region.tf`).
In the root `terraform.tfvars`:

```hcl
enable_region_b           = true
enable_global_accelerator = true
# Region B CIDR plan defaults to 10.2x.0.0/16; region_b_create_app/dc default false
```

**Apply in two phases** (this matters — a single `apply` fails):

```bash
# 1. Stand up Region B on its own first. cross_region.tf's for_each iterates
#    over Region B route-table IDs, which are unknown until Region B exists, so
#    a full apply errors with "Invalid for_each argument".
terraform apply -target=module.region_b
# 2. Now the full apply wires the TGW peering + cross-region routes + GA.
terraform apply
terraform output global_accelerator_static_ips   # the 2 anycast IPs the client keeps
terraform output global_accelerator_dns_name     # CNAME target for the portal FQDN
```

Then add the Region B gateway to `gp_external_gateways` in the panos workspace
and re-apply so the portal advertises both regions.

**Multi-region prerequisites** (all handled in code — listed so a clean deploy
knows what to expect):

- **EC2 key pairs are region-local.** Set root `ssh_public_key` so each region
  auto-creates the same-named key pair; otherwise Region B fails with "key pair
  does not exist" until you import it by hand.
- **TGW peering acceptance is eventually-consistent.** The cross-region routes
  and associations can fail once with `IncorrectState` on the first apply while
  the peering is still becoming `available` — **just re-run `terraform apply`**;
  it converges on the second pass.
- **Panorama's own SG must admit the remote region's firewall CIDR** on the
  PAN-OS control plane (3978/28443). Handled by root `remote_fw_cidrs`
  (Region B's `security_vpc_cidr_b`, passed automatically). Without it Region B
  FWs reach Panorama over peering but its SG drops them → `Connected=no`.
- **The SSM jump host needs a cross-region route** to Region B firewall mgmt so
  `scripts/configure-ha.sh` can SSH the Region B pair for native-HA config.
  Handled by `aws_route.a_ssm_to_b` in `cross_region.tf`.
- **`scripts/configure-ha.sh` targets SSM in the JUMP HOST's region**
  (`AWS_REGION` defaults to `eu-central-1` = Region A, where the jump host
  lives) — not the firewall's region. Region B FWs first-boot (upgrade +
  restart + license) takes **~35 min** before they register.
- **Cross-region spoke2↔spoke2 routes** (`cross_region.tf`, 4 TGW routes) let the
  two AD DCs replicate and let each region's firewalls query both DCs for GP
  LDAP. Added automatically with `enable_region_b`. No VPC routes needed (spoke2
  already defaults 0/0→TGW; delivery via the TGW module's `security_to_spokes`).

### Region B additional DC + resilient LDAP (order matters)

For VPN login to survive a whole-region outage, run a **second AD DC in Region B**
joined to the same `panw.labs` forest (native multi-master replication), and list
BOTH DCs in the GP LDAP profile. **Sequence matters** — a single big apply fails,
because the Region B DC can only promote once the Region A DC exists and
cross-region routing is up:

1. **Region A first, fully.** Phases 1a→2a→1b→2b→3 complete; the Region A DC is
   promoted (`Get-ADDomain` works). This is the forest.
2. **Region B networking + firewalls.** `enable_region_b=true`, two-phase apply
   (`-target=module.region_b`, then full) — brings up Region B + TGW peering +
   the cross-region routes. Register + HA the Region B firewalls (Phase 2b/HA).
3. **Region B DC (additional).** Set `region_b_create_dc=true` and apply. Root
   wires it as an **additional DC** (`dc_is_additional`, `dc_primary_ip =
   module.region_a.dc_private_ip`, promotion credential = the AD test user, which
   `scripts/create-ad-test-user.sh` makes a **Domain Admin**). Its user-data
   points DNS at the Region A DC, joins the domain, and runs
   `Install-ADDSDomainController`. It reboots once (~25–40 min). The DC security
   group opens the **full AD/replication port set** (dynamic RPC 49152-65535 etc.)
   — required, or promotion silently fails.
   - Verify from the Region A DC (SSM RunCommand):
     `Get-ADDomainController -Filter *` shows both DCs;
     `repadmin /replsummary` shows `0 fails`.
4. **Resilient LDAP.** Get the Region B DC IP (`terraform output dc_private_ip_b`),
   add it to phase2 `gp_ldap_extra_server_ips = ["<ip>"]` and to `gp_dns_servers`
   (list both DCs), re-apply phase2. PAN-OS then fails LDAP over between DCs.
   Three things are required for auth to survive a region outage (all in code):
   - **Fast failover between DCs (`gp_ldap_bind_timelimit`, default 3s).** The
     LDAP server list is template-wide (one template for both regions), so a
     firewall in the surviving region still tries the first-listed DC first — and
     if that DC is in the dead region, PAN-OS's default **30s** per-server connect
     wait exceeds the GP getconfig timeout, and login fails. Capping the
     per-server connect wait (`bind_timelimit`) makes auth fail over to the
     surviving-region DC in a few seconds.
   - **Firewalls must reach BOTH DCs.** `cross_region.tf` adds a FW-mgmt-subnet
     route to the peer region's spoke2 CIDR (`a_fwmgmt_to_b_dc` /
     `b_fwmgmt_to_a_dc`) so each region's FW can bind either DC.
   - **The additional DC's DNS client points at ITSELF first** (post-promotion
     step in `modules/spoke2_dc`) so the surviving DC keeps working DNS during a
     primary-region outage. LDAP *binds* are answered from the DC's local
     replicated AD copy and don't require DNS, but self-first DNS keeps the rest
     of the DC healthy.
   - When recreating the additional DC, note that terminating it is not a
     graceful demote and leaves a lingering DC object in AD — run a metadata
     cleanup on the primary DC (`ntdsutil` / `Remove-ADDomainController
     -ForceRemoval`) before re-promoting a replacement at the same name/IP.

> On a first clean multi-region bring-up, deploy Region A end-to-end and confirm
> GP login works there before adding the Region B DC, so any regression is easy
> to localize.

---

## Optional — EKS + WordPress + EDL

See `optional/eks-deploy/README.md`. Order matters: bring up the EDL
server + EKS VPC, enable the EDL rules in the panos workspace
(`enable_edl=true`, `edl_server_ip=<ip>`) so node-bootstrap endpoints are
permitted **before** nodes join, then the node group + Helm WordPress converge.

---

## Accessing the environment

**➡️ Full remote-access guide: [docs/ACCESS.md](ACCESS.md)** — RDP to the Windows
domain controller, the Panorama web GUI/API, and firewall CLI, with copy-paste
commands. Everything is reached through AWS SSM Session Manager (no bastion, no
public management IPs). The essentials:

- **Windows DC (RDP):** the DC has its own SSM agent, so port-forward directly —
  `aws ssm start-session --target $(terraform output -raw dc_instance_id)
  --document-name AWS-StartPortForwardingSession
  --parameters '{"portNumber":["3389"],"localPortNumber":["13389"]}'`, then RDP to
  `localhost:13389` as `Administrator` (password: `aws ec2 get-password-data`).
- **Panorama (GUI/API) & firewalls (SSH):** PAN-OS has no SSM agent, so
  port-forward *through the jump host* (`AWS-StartPortForwardingSessionToRemoteHost`
  to the target's private IP) — `https://localhost:44300` for Panorama,
  `ssh admin@localhost -p 2211` for a firewall. `scripts/configure-panorama.sh
  tunnel` wraps the Panorama one.

See **[docs/ACCESS.md](ACCESS.md)** for the exact commands, ports, and
troubleshooting.

---

## Verification

```bash
# Panorama reachable + system info (tunnel up)
PANORAMA_PASSWORD=<pw> bash scripts/check-panorama.sh

# Connected FWs on Panorama
curl -sk "https://localhost:44300/api/?type=op&cmd=<show><devices><connected></connected></devices></show>&key=<APIKEY>"

# FW bootstrap status (SSH via jump host to a FW mgmt IP)
#   show system bootstrap status
#   show high-availability state         # one active, one passive
```

- App: browse the CloudFront domain → CloudFront → app NLB → FW DNAT → Apache.
- GP: connect the GlobalProtect agent to the portal FQDN.

---

## Testing traffic flows

- **Inbound app:** `curl https://<app_cloudfront_domain>/` → the Spoke1 "hello
  world" page. Path: CloudFront → NLB (IP target = FW untrust) → FW DNAT → Apache.
- **Outbound (spoke → internet):** from the DC/app host, egress goes spoke → TGW
  → FW trust → SNAT → FW untrust EIP → IGW (inspected).
- **East-west (spoke ↔ spoke):** TGW spoke route table forces it through the FWs
  (appliance mode keeps flow symmetry, so a single VR suffices).
- **GP:** connect the agent; verify the assigned IP-pool address and that
  split-tunnel routes reach spoke resources.

Check logs in Panorama (Monitor → Traffic) or via the API.

---

## HA & failover

| Failure | Covered by |
|---------|-----------|
| Single FW dies | Active/Passive HA — the AWS HA plugin moves the untrust floating IP + EIP (`AssociateAddress`) and rewrites the inspection route (`ReplaceRoute`) to the peer |
| Whole AZ dies | The other region's gateway (GP-native failover); intra-region cross-AZ is a documented future option |
| Whole region dies | GP-native gateway failover + Global Accelerator moves the portal to the healthy region |
| Panorama dies | FWs keep running last-pushed config; management only. HA-Panorama = v2 |

### Configuring native PAN-OS HA

Native HA (Setup/Election/Control-Link/Data-Link) is **not** covered by the
`panos` Terraform provider at all, and is device-local config (each firewall
has its own peer-ip/device-priority), not something Panorama's shared
template/device-group push can express. It's pushed directly per-firewall via
`scripts/configure-ha.sh` (same direct-SSH pattern as
`scripts/set-panorama-password.sh`), **after** `phase2-panorama-config` has
already pushed the `ha2`/`untrust` interface config (Phase 2a must be current
first — the `ha2` interface object and the `untrust` rename to `ethernet1/3`
have to exist before HA config references `ethernet1/1` as HA2).

> **This is a REQUIRED manual step, and it is NOT part of `terraform apply`.**
> Because HA config is device-local (not Panorama-managed), any operation that
> **recreates a firewall** — a from-scratch redeploy, `terraform apply -replace`,
> or a version bump that swaps the AMI — comes back with **`HA not enabled`**, and
> failover will not move the EIP or TGW route. Re-run `configure-ha.sh` for BOTH
> firewalls after any such recreation, then verify with `show high-availability
> state` (below) before relying on failover.

```bash
# fw1 (preferred active — lower device-priority)
JUMP=$(cd .. && terraform output -raw ssm_jumphost_instance_id) \
FW_IP=<fw1 mgmt private IP> PEER_IP=<fw2 mgmt private IP> \
DEVICE_PRIORITY=100 HA2_IP=<fw1 ha2 ENI private IP> \
KEY_FILE=~/.ssh/<key_name>.pem \
  bash scripts/configure-ha.sh

# fw2 (passive) — higher device-priority, peer-ip/HA2_IP swapped
JUMP=$(cd .. && terraform output -raw ssm_jumphost_instance_id) \
FW_IP=<fw2 mgmt private IP> PEER_IP=<fw1 mgmt private IP> \
DEVICE_PRIORITY=110 HA2_IP=<fw2 ha2 ENI private IP> \
KEY_FILE=~/.ssh/<key_name>.pem \
  bash scripts/configure-ha.sh
```

Get the mgmt/ha2 private IPs from `aws ec2 describe-network-interfaces
--filters "Name=tag:Name,Values=<name_prefix>-a-fw1-mgmt"` (repeat per
ENI/firewall) if not already known.

**Prerequisite security group rules** (already in
`modules/region_stack/main.tf`'s `fw-mgmt` security group, but worth knowing
why): HA1 (control link) runs over the management interface and needs **TCP
28769 + 28260** open between the firewalls' mgmt IPs, **and ICMP** — the HA1
heartbeat itself is an ICMP echo sent before the TCP link is ever attempted.
Missing either half looks identical: `show high-availability state` reports
`Connection status: down` / `Never able to connect to peer` indefinitely.

**Verify:**
```
show high-availability state
```
Expect one firewall `State: active`, the other `State: passive`,
`Connection status: up` on both, `Running Configuration: synchronized`. If
config changed while the peers were disconnected, force a resync from the
active unit: `request high-availability sync-to-remote running-config`.

### Testing failover

Use the on/off helper `scripts/failover-test.sh`, which drives both scenarios
via the AWS API only (EC2 stop/start + describe — no SSH, no tunnel):

```bash
scripts/failover-test.sh status a          # show HA state of the Region A pair
scripts/failover-test.sh ha     a down     # suspend the active unit -> peer takes over
scripts/failover-test.sh ha     a up        # restore (rejoins as passive, no preempt)
scripts/failover-test.sh region a down     # simulate a whole-region outage (stop the pair)
scripts/failover-test.sh region a up        # bring the region back
```

Expected results (after `configure-ha.sh` — see the REQUIRED-step note above):

- **HA failover** (`ha a down`): stopping the active `fw1` moves the untrust
  floating IP, its Elastic IP, **and** the TGW `0.0.0.0/0` inspection route to
  `fw2` automatically (PAN-OS AWS HA plugin) — verifiable at the AWS level
  (`describe-network-interfaces` / `describe-addresses` / `describe-route-tables`).
  `fw2` serves the portal on the Region A EIP once its dataplane warms (~2-3 min);
  the anycast portal FQDN stays `Success` throughout via GA. `ha a up` brings
  `fw1` back as **passive** (preemption off — clean failback, no flap).
- **Region outage** (`region a down` + stopping the Region A DC): Global
  Accelerator drops the Region A endpoint and serves the portal via Region B; GP
  **AD auth** through the anycast FQDN succeeds in a few seconds (LDAP fails over
  to the Region B DC — see the `gp_ldap_bind_timelimit` note under Phase R2).

Or do it by hand to see the moving parts:

```
# On the active firewall:
request high-availability state suspend
```
Verify from AWS (not just PAN-OS) that the failover actually moved the
network-facing resources — this is the part the AWS HA plugin does, not
PAN-OS itself:
```bash
aws ec2 describe-addresses --filters "Name=private-ip-address,Values=<floating IP>" \
  --query 'Addresses[0].NetworkInterfaceId'   # should now be the peer's untrust ENI
aws ec2 describe-route-tables --route-table-ids <tgw-attach route table ids> \
  --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NetworkInterfaceId'
  # should now be the peer's trust ENI
```
Restore: `request high-availability state functional` on the suspended unit.
Preemption is intentionally off (PANW's own recommendation for HA on AWS), so
the restored unit correctly rejoins as **passive** rather than reclaiming
active — don't expect it to flip back automatically.

### GlobalProtect — how it's wired

The GlobalProtect portal + tunnel-mode gateway are configured in the panos
workspace. The implementation relies on the following details, several of which
work around gaps in the `panos` provider:

1. **`local_address` needs an IP actually configured on the interface.** The
   provider forces exactly one of `ip`/`floating_ip` (a ConfigValidator, caught
   at `terraform validate`), and PAN-OS then needs that IP present on the
   interface. The untrust interface is therefore **static**, with a per-device
   **primary** IP (`.11`/`.12`) via `panos_template_variable` overridden by
   serial, plus a shared **floating** `.100/32` (must be /32 — two /24s on one
   interface produce an "overlapping subnet" error). GP binds the floating IP.
2. **The provider can't set more than one per-device template variable**
   (`"At most 1 occurrence for devices/entry"`), so the per-device overrides are
   set via the raw XML API (`scripts/set-untrust-overrides.sh`).
3. **`panos_device_group`/`panos_template_stack` own `devices`.** Left unset,
   every apply un-assigns the firewalls, so shared policy stops reaching them.
   Both use `lifecycle { ignore_changes = [devices] }`; membership is set by the
   register script.
4. **Inbound GP is untrust→untrust self-traffic**, which the deny-all rule would
   otherwise catch. An explicit allow to the floating IP `:443` sits before
   deny-all.
5. **Portal external-gateway IP goes in `<ip>`, not `<fqdn>`** (the `gp.tf`
   regex routes IP vs FQDN automatically).
6. **A tunnel-mode gateway needs a SECOND config subtree** the provider can't
   write: `network/tunnel/global-protect-gateway` (`<tunnel-interface>` +
   `<local-address>`). Without it the firewall commit fails with
   `gp_broker: <local-address> tag does not exist`. It is created via the XML API
   (`scripts/set-gp-tunnel-node.sh` / `null_resource.gp_tunnel_node`); the client
   IP pool must live in exactly one place (`remote_user_tunnel_configs`), and the
   tunnel interface must be in a virtual router.

**Auth requirements** (both preserved in code; changing either returns HTTP 512 /
`X-Private-Pan-Globalprotect: auth-failed` for local and LDAP users alike):

- **Auth-profile location** — the GP auth profiles must be at the **vsys1**
  location (`local.gp_tpl_vsys`), not template-shared: the GP portal/gateway and
  local users are vsys1, and a shared local-database profile can't see a vsys1
  user (for LDAP the FW doesn't even query the DC).
- **phash (local users)** — `panos_local_user` writes the password verbatim into
  `<phash>` without hashing; `scripts/set-gp-local-users.sh` hashes it with
  `openssl passwd -1` instead.

For multi-region, the floating IP, untrust default-gateway, and trust-gateway
all become **per-region template variables** (`$fw_untrust_floating`,
`$fw_untrust_gw`, `$fw_trust_gw`) overridden per-device — otherwise Region B
inherits Region A's `10.10.x` values and can't bind GP or route to the internet.

---

## Teardown

Reverse order; destroy the panos workspace and optional stacks first.

```bash
# optional EKS
( cd optional/eks-deploy && terraform destroy )
# panos config
( cd phase2-panorama-config && terraform destroy )
# root (all regions)
terraform destroy
```

> EIPs and the Global Accelerator incur cost while allocated — confirm they are
> released. Marketplace subscriptions persist (harmless).

---

## Troubleshooting

- **GP app: "Connection Failed — Could not connect to the GlobalProtect
  service"** (and `PanGPA.log` shows `CPanSocket::onConnect ... error code =
  10061`, with the driver log reporting `0xE000022F` / `Driver installation
  failed with error = 2` / `Driver is not installed`) → the GlobalProtect
  kernel driver didn't install, so the local `PanGPS` service can't run and the
  UI can't reach it. The portal is never contacted — this is **not** an
  environment/config problem. The usual cause is a **CPU-architecture mismatch**:
  the **x64 installer on a Windows-on-ARM** machine (ARM64 Windows can't load an
  x64 kernel driver). Use a native x64 Windows client, or the native ARM64 GP app
  — see the "Client platform matters" note under [Phase GP](#phase-gp--globalprotect).
- **FW shows `Connected: no` despite valid device certs, licenses, and a
  correct PAN-OS version pair** → this is usually **not** network, cert, or
  license — it's a **silently failed Panorama commit**. `modules/
  panorama_config/main.tf`'s `panos_template_stack` sets `default_vsys =
  "vsys1"`; without it, PAN-OS rejects **any commit** that assigns a device to
  that template-stack with `Validation Error: devices -> localhost.localdomain
  -> template-stack -> <name> is missing 'settings'`. Because `commit` is
  atomic, this discards the ENTIRE commit — including unrelated mgt-config/
  device-group changes staged in the same commit — while every
  `type=config&action=set` API call still reports `"success"` (it only stages
  candidate config; only the commit itself validates). Check the commit job's
  actual result (`type=op&cmd=<show><jobs><id>N</id></jobs></show>`, look for
  `Validation Error` in the detail line) before concluding the config was
  applied.
  - **To rule out the network authoritatively**, use the **AWS VPC Reachability
    Analyzer** (`aws ec2 create-network-insights-path --source <FW-ENI>
    --destination <Panorama-ENI> --protocol tcp --destination-port 3978`, then
    `start-network-insights-analysis`). It walks the actual SG/NACL/route-table
    chain and gives a definitive `NetworkPathFound: true/false`.
- **`OptInRequired` on launch** → AMI not subscribed (Phase 0). Verify with
  `scripts/accept-marketplace-terms.sh`, which does a real subscription check
  (`ec2 run-instances --dry-run`: `OptInRequired` = not subscribed,
  `DryRunOperation` = subscribed) — AMI *visibility* via `describe-images` is
  **not** a valid proxy (Marketplace AMIs are visible to everyone regardless
  of subscription).
- **FW never registers** → check the vm-auth-key file was written by Phase 2a,
  `fw_auth_code` credit balance, and PIN validity; `show system bootstrap status`.
- **No failover** → the FW IAM instance profile (bootstrap module) must carry the
  HA-plugin EC2 permissions; no IAM → no failover.
- **Asymmetric-drop through the FWs** → `appliance_mode_support = enable` must be
  set on the security-VPC TGW attachment (it is, in the tgw module).
- **NLB health checks fail** → the FW interface-mgmt profile must permit the VPC
  CIDR (NLB health checks originate from within the VPC).
- **panos apply hangs/locks** → a Panorama commit/collector job holds the config
  lock; wait, then retry (the provider timeout is generous).
- **Region B FW can't reach Panorama** → check the cross-region TGW peering
  routes in `cross_region.tf` against the live topology.
- **GP LDAP auth fails / times out (`gp_auth_method = ldap`)** → the FW's LDAP
  bind goes out its **mgmt interface** by default, which needs an explicit
  route to the spoke2 (DC) CIDR — `modules/region_stack/main.tf`'s
  `tgw_routes_in_vpc` adds this (`sec-spoke2-*` entries, mirroring the
  Panorama↔FW-mgmt pattern). If the bind still times out, use the **AWS
  Reachability Analyzer** (see the `Connected: no` entry above) between a
  security-VPC mgmt-subnet ENI and the DC's ENI on TCP/389 to confirm the path.
- **Apache/WordPress didn't install** → the host waits on the FW egress policy
  (Phase 2b); the systemd installer retries every 60s indefinitely —
  `/var/log/cloud-init-apache.log`.
- **A spoke/DC has no internet access at all, and the FW's traffic log shows
  nothing** (not even a deny) → check whether the security policy actually
  reached the firewall's **running** config, not just Panorama's candidate
  config: `show running security-policy` on the FW directly (SSH). If it
  shows only `intrazone-default`/`interzone-default`, the push did not land —
  re-run `scripts/configure-panorama.sh commit` (it polls jobs and fails loudly;
  if it reports a real error, see the content-version and NAT entries below).
  Confirm with `debug dataplane packet-diag`: a
  `flow_policy_deny` counter (not zero traffic) means packets ARE arriving
  but hitting a deny — matches this scenario, whereas zero packets at all
  points elsewhere (routing, security group, NACL).
- **Panorama push fails with `Duplicate application name 'X'`** (X often
  looks unrelated, e.g. a `content-preview`/pre-release app signature) → the
  Panorama and firewall `app-version` (App-ID/Threat content) don't match —
  check with `show system info | match app-version` on all three. Fix:
  `request content upgrade install version latest` on Panorama and every
  firewall so they're all on the identical version, then retry the push.
- **A spoke can reach the firewall but the connection just times out (no
  deny, no reset — traced to a real, allowed session in `show session all`)**
  → check the NAT rule's `source_translation`. `dynamic_ip_and_port` with
  `interface_address` SNATs to the interface's own address, which — if
  that's the DHCP-leased primary rather than an EIP-backed secondary/floating
  IP — has no path back from the internet. Use `translated_address` (a
  literal IP/pool) pointed at the address that actually has the EIP.
- **`show high-availability state` — `Connection status: down`, `Never able
  to connect to peer`, indefinitely** → see [Configuring native PAN-OS
  HA](#configuring-native-pan-os-ha): almost always the `fw-mgmt` security
  group missing either the HA1 TCP ports (28769/28260) or ICMP (the
  heartbeat itself). Check `mp-log ha_agent.log` for `"waiting for ping
  response before starting connection"` — that's the ICMP half specifically.
- **`show interface hardware`/`show interface all` seems to be missing a
  physical interface you know is attached** (`aws ec2
  describe-network-interfaces` shows 4 ENIs, PAN-OS shows 3) → this is **not**
  a hardware/AWS problem. These commands only list PAN-OS-*configured*
  interfaces (`"total configured hardware interfaces"` is literal) — add a
  `panos_ethernet_interface` resource for the missing one (even a bare
  `ha = {}` for an HA-type interface with no IP config) and it appears
  immediately, no reboot needed.
- **Renaming a `panos_ethernet_interface` via `terraform apply` fails**
  (`object already exists` on update, or "cannot be deleted because of
  references" on `-replace`) → rename via the raw XML API instead
  (`type=config&action=rename&xpath=...&newname=...`), which cascades to
  every referencing zone/VR/route atomically; then `terraform state rm` +
  `terraform import` (base64-encoded JSON `{"location": {...}, "name":
  "..."}` — include every location sub-field the live object actually has,
  e.g. `vsys`, or the next plan wants to replace it).

## Key variables

**Root (`terraform.tfvars`):** `region_a`/`region_b`, `*_vpc_cidr[_b]`,
`panorama_*`, `fw_auth_code`, `fw_registration_pin_*`, `fw_instance_type`,
`key_name`, `dc_*`, `enable_region_b`, `enable_global_accelerator`,
`region_b_create_app`/`_dc`.

**panos workspace (`phase2-panorama-config/terraform.tfvars`):**
`panorama_password`, `template_name`/`template_stack_name`/`device_group_name`
(match root), `untrust_gateway_ip`/`trust_gateway_ip`, `app_dnat_public_ip`/
`app_private_ip`, `enable_globalprotect` + `gp_*`, `enable_edl` + `edl_server_ip`,
`enable_log_collector`.

Full descriptions live in each `variables.tf`.
