# Prerequisites — workstation setup & AWS access

Everything you must have **on your machine** and **in your accounts** before
`terraform apply` will work against AWS. Do this once. Then follow
[docs/DEPLOYMENT.md](DEPLOYMENT.md) for the phased deploy and
[docs/CONFIGURATION.md](CONFIGURATION.md) for which parameter goes in which file.

**Contents:** [Accounts](#1-accounts-you-need) · [Tools](#2-tools-to-install) ·
[AWS CLI login](#3-aws-cli-authentication) · [Verify](#4-verify-everything) ·
[Deployer IAM](#5-deployer-iam-permissions) · [Quotas & region](#6-quotas--region)
· [SSH key pair](#7-ssh-key-pair) · [Get the code](#8-get-the-code)

---

## 1. Accounts you need

| Account | Why | Where |
|---------|-----|-------|
| **AWS account** | deploy target | https://aws.amazon.com — an IAM/SSO identity you can log in with from the CLI |
| **Palo Alto CSP account** | VM-Series/Panorama **BYOL** auth codes (from a **Software NGFW Credits Deployment Profile** — size: **2 FW** for Region A / **4** for A+B, **4 vCPU/FW default** (`m5.xlarge`; 8 vCPU for headroom), incl. GlobalProtect; see [CONFIGURATION.md](CONFIGURATION.md#where-the-panw-values-come-from-csp-portal)) + device-cert registration PIN | https://support.paloaltonetworks.com |
| **AWS Marketplace subscriptions** | one-time, per AWS account, for the VM-Series + Panorama AMIs (console-only) | see [DEPLOYMENT.md Phase 0](DEPLOYMENT.md#phase-0--prerequisites) |
| **GitHub** | clone this public repo | `mzalewski87/aws_ha_project` |

---

## 2. Tools to install

| Tool | Min version | Used for |
|------|-------------|----------|
| **Terraform** | 1.5+ (repo pins/tests on **1.15.5**) | the IaC itself |
| **AWS CLI v2** | latest | auth + `terraform output` handoffs + a few helper scripts |
| **Session Manager plugin** | latest | the SSM tunnel to Panorama/FWs (no bastion) |
| **git** | any recent | clone/pull |
| **GitHub CLI (`gh`)** | optional | PRs/repo ops |
| **jq**, **curl** | any | helper scripts / API calls |
| **kubectl** + **helm** | kubectl ~1.30, helm 3 | **only** for the optional EKS add-on |

### macOS (Homebrew)
```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform awscli session-manager-plugin git gh jq
# EKS add-on only:
brew install kubernetes-cli helm
```
> Prefer to pin Terraform to 1.15.5 (matches CI)? Use `tfenv`:
> `brew install tfenv && tfenv install 1.15.5 && tfenv use 1.15.5`.

> **No admin / can't `sudo`?** Everything above installs as a Homebrew *formula*
> (no sudo) **except** `session-manager-plugin`, which is a *cask* that runs a
> `sudo` installer. Install it user-locally instead (no admin), by extracting the
> official AWS pkg into `~/.local/bin`:
> ```bash
> # Apple Silicon; for Intel use .../plugin/latest/mac/session-manager-plugin.pkg
> URL=https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/session-manager-plugin.pkg
> W=$(mktemp -d); curl -fsSL -o "$W/smp.pkg" "$URL"
> pkgutil --expand-full "$W/smp.pkg" "$W/x"            # no sudo
> mkdir -p ~/.local/bin
> cp "$(find "$W/x" -type f -name session-manager-plugin | head -1)" ~/.local/bin/
> chmod +x ~/.local/bin/session-manager-plugin; rm -rf "$W"
> echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
> session-manager-plugin --version                     # e.g. 1.2.835.0
> ```
> The AWS CLI finds the plugin on `PATH`, so `aws ssm start-session …` then works.
> (The unrelated `powershell/tap` "not trusted" warning from `brew` can be
> ignored.)

### Linux (Ubuntu/Debian)
```bash
# Terraform (HashiCorp apt repo)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform git jq

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# Session Manager plugin
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o smp.deb
sudo dpkg -i smp.deb

# gh (optional)
sudo apt install -y gh
# EKS add-on only: kubectl + helm
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && sudo install kubectl /usr/local/bin/
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Windows
Use **winget** (`winget install Hashicorp.Terraform Amazon.AWSCLI Amazon.SessionManagerPlugin Git.Git GitHub.cli`)
or run everything from **WSL2 Ubuntu** with the Linux steps above (recommended —
the helper `scripts/*.sh` are bash).

---

## 3. AWS CLI authentication

Terraform's AWS provider uses the **standard AWS credential chain** — the same
credentials the `aws` CLI uses. You do **not** put AWS keys in any `.tf`/tfvars.
Pick ONE of the methods below and make sure `aws sts get-caller-identity` works.

### Option A — IAM Identity Center / SSO (recommended)
> **`SSO region` = the region where IAM Identity Center lives — NOT your deploy
> region.** These are usually different (e.g. Identity Center in `us-west-2`,
> deploy in `eu-central-1`). Getting it wrong is the #1 login failure: it throws
> `InvalidRequestException` / `error: invalid_request` / `Invalid request.` on
> `RegisterClient` or `StartDeviceAuthorization`. Check the correct region in the
> IAM Identity Center console (top-right), or probe it (see Troubleshooting below).
```bash
aws configure sso
#   SSO session name:   e.g. awsha
#   SSO start URL:      https://<your-org>.awsapps.com/start/
#   SSO region:         region of Identity Center (e.g. us-west-2) — NOT the deploy region
#   SSO registration scopes: sso:account:access  (default is fine)
#   pick account + role (needs the permissions in section 5)
#   CLI default client Region: your DEPLOY region (e.g. eu-central-1)
#   profile name:       e.g. awsha
aws sso login --sso-session awsha
export AWS_PROFILE=awsha         # Terraform will use this profile
export AWS_REGION=eu-central-1   # optional; providers.tf already sets regions
```
> If login still errors after the region is confirmed correct, add
> `--use-device-code` to both `configure sso` and `sso login` (some CLI/IdC
> combos dislike the default authorization-code + PKCE flow).
>
> **Troubleshooting `Invalid request.` — find the real Identity Center region.**
> `RegisterClient` succeeds in any region (it only mints an OIDC client), so the
> failure surfaces one step later. Probe each region — the one returning a
> `clientId` is the correct `sso_region`:
> ```bash
> ISS="https://<your-org>.awsapps.com/start/"
> for R in us-east-1 us-west-2 eu-central-1 eu-west-1 ap-southeast-1; do
>   curl -s -X POST "https://oidc.$R.amazonaws.com/client/register" \
>     -H "Content-Type: application/json" \
>     -d "{\"clientName\":\"probe\",\"clientType\":\"public\",\"scopes\":[\"sso:account:access\"],\"grantTypes\":[\"authorization_code\",\"refresh_token\"],\"redirectUris\":[\"http://127.0.0.1:8080/oauth/callback\"],\"issuerUrl\":\"$ISS\"}" \
>     | grep -q '"clientId"' && echo "$R -> correct region"
> done
> ```

### Option B — IAM user access keys
Create an access key in the AWS console (IAM → Users → Security credentials →
Create access key → "Command Line Interface"), then:
```bash
aws configure --profile awsha
#   AWS Access Key ID / Secret Access Key
#   Default region: eu-central-1
export AWS_PROFILE=awsha
```
> Long-lived keys are the least-preferred option; rotate them and never commit
> them. `~/.aws/credentials` is outside this repo and stays there.

### Option C — Named profile + MFA / assume-role
If your org requires assuming a role, add to `~/.aws/config`:
```ini
[profile awsha]
region = eu-central-1
source_profile = default
role_arn = arn:aws:iam::<ACCOUNT_ID>:role/<DeployRole>
mfa_serial = arn:aws:iam::<ACCOUNT_ID>:mfa/<your-user>
```
`export AWS_PROFILE=awsha` — the CLI/Terraform prompt for the MFA token as needed.

### How Terraform picks it up
- `providers.tf` sets **regions** (`region_a`, `region_b`, and `us-west-2` for
  Global Accelerator) but **no credentials** — those come from `AWS_PROFILE` /
  env vars / `~/.aws`.
- Run every `terraform` command in the same shell where `AWS_PROFILE`/
  `AWS_REGION` are exported (or where `aws sso login` is still valid).

---

## 4. Verify everything

```bash
terraform -version                 # >= 1.5 (ideally 1.15.5)
aws --version                      # aws-cli/2.x
session-manager-plugin             # prints the plugin version/OK
aws sts get-caller-identity        # must return YOUR account/user — the key test
# EKS add-on only:
kubectl version --client && helm version
```
If `get-caller-identity` fails, fix auth (section 3) before going further —
Terraform will fail the same way.

---

## 5. Deployer IAM permissions

The identity you log in with must be able to create/destroy the resources this
project uses. For a lab/PoC, an admin-ish policy is simplest; for least
privilege, the deployer needs at least:

- **EC2 / VPC / networking:** VPCs, subnets, route tables, IGW, NAT GW, EIPs,
  ENIs, security groups, instances, key pairs, **Transit Gateway** (+ attachments,
  route tables, **peering** for R2).
- **IAM:** create roles / instance profiles / policies (FW HA-plugin role, EDL/
  jump-host/EKS roles) and **PassRole** for them.
- **SSM:** `StartSession` (+ the `AWS-StartPortForwardingSessionToRemoteHost`
  document) for the tunnel.
- **ELB v2** (NLB), **CloudFront**, **Global Accelerator** (control plane in
  us-west-2), **EKS** + node-group (optional add-on).
- **Marketplace:** ability to launch the subscribed AMIs.

> Managed-policy shortcut for a lab: `AdministratorAccess`. Tighten later.

---

## 6. Quotas & region

- **Default region** is `eu-central-1` (Region A) / `eu-west-1` (Region B). Change
  via `region_a`/`region_b` — but then also re-check the CIDR/AZ assumptions and
  that the BYOL AMIs are available there.
- **vCPU quota (On-Demand Standard, e.g. m5):** the FWs default to `m5.xlarge`
  (4 vCPU each ×2; `m5.2xlarge` = 8 vCPU if you bump it) and Panorama is
  `m5.4xlarge` (16 vCPU) — request a quota increase if your account is capped low
  (Service Quotas → EC2 → "Running On-Demand Standard").
  This is the **AWS EC2** quota — separate from the **PANW license vCPU** you set
  in the Software NGFW Deployment Profile (see
  [CONFIGURATION.md](CONFIGURATION.md#where-the-panw-values-come-from-csp-portal)).
  They must agree: license 4 vCPU/FW ⇔ deploy `m5.xlarge` (or 8 ⇔ `m5.2xlarge`).
- **Elastic IPs:** default limit is 5 per region; this project uses several
  (NAT GWs + FW public EIP). Raise if needed.
- **Marketplace subscribe is one-time per account** and console-only — see
  [Phase 0](DEPLOYMENT.md#phase-0--prerequisites) / `scripts/accept-marketplace-terms.sh`.

---

## 7. SSH key pair

An EC2 key pair (name → `key_name`) sets Panorama's initial admin SSH key and
decrypts the Windows DC Administrator password. Create the private key once:
```bash
aws ec2 create-key-pair --key-name awsha-key \
  --query 'KeyMaterial' --output text > ~/.ssh/awsha-key.pem
chmod 600 ~/.ssh/awsha-key.pem
# then set:  key_name = "awsha-key"   in terraform.tfvars
```

**EC2 key pairs are region-local.** For a **multi-region** deploy the same-named
key must exist in every region. The clean way: put your **public** key in
`ssh_public_key` and Terraform creates the key pair in each region for you (no
manual per-region import):
```bash
# public key for the pair created above:
ssh-keygen -y -f ~/.ssh/awsha-key.pem > ~/.ssh/awsha-key.pub
# then set in terraform.tfvars:
#   key_name       = "awsha-key"
#   ssh_public_key = "ssh-rsa AAAA... (contents of awsha-key.pub)"
```
Leave `ssh_public_key` empty only if you've already imported `key_name` into
every target region by hand.

---

## 8. Get the code

This repo is the **source of truth** — run `apply` from a **separate clone**, not
the source tree.
```bash
git clone https://github.com/mzalewski87/aws_ha_project.git
cd aws_ha_project
cp terraform.tfvars.example terraform.tfvars   # then fill it — see CONFIGURATION.md
```

Next: **[docs/CONFIGURATION.md](CONFIGURATION.md)** (what to put where) →
**[docs/DEPLOYMENT.md](DEPLOYMENT.md)** (the phased apply).
