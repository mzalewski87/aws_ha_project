# Accessing the environment (RDP / Panorama / firewall CLI)

Nothing here has a public management IP and there is **no bastion** — every
management plane is reached through **AWS SSM Session Manager** (no inbound ports
opened). Two patterns:

- **Windows domain controller** — has its own SSM agent, so you port-forward
  **directly** to the instance.
- **Panorama and the VM-Series firewalls** — PAN-OS runs no SSM agent, so you
  port-forward **through the SSM jump host** to the target's private IP (an SSM
  *RemoteHost* forward).

---

## 0. Before you connect (do this once per shell)

Every command below needs the AWS CLI **authenticated** and a **region set** —
the two most common failures are `You must specify a region` (`NoRegion`) and an
expired/absent login. This section uses the profile name **`awsha`** as the
example throughout; if your profile has a different name, substitute it. (The
commands below are literal — do **not** paste angle-bracket placeholders like
`<...>` into a shell; that's a syntax error.)

**Step 1 — find or create your AWS CLI profile.** List what you already have:

```bash
aws configure list-profiles
```

- If it prints a name (e.g. `awsha`), use that name as `AWS_PROFILE` in step 2.
- If it prints **nothing** (or errors), create one now — pick ONE:

  **A) IAM Identity Center (SSO)** — recommended:
  ```bash
  aws configure sso
  # answer the prompts:
  #   SSO session name        : awsha
  #   SSO start URL           : https://<your-org>.awsapps.com/start/   (from your admin)
  #   SSO region              : the region where Identity Center lives (e.g. us-west-2)
  #   registration scopes     : sso:account:access   (default)
  #   pick your account + role
  #   CLI default client Region : eu-central-1
  #   CLI default output      : json
  #   profile name            : awsha
  ```
  (Full walkthrough + the "Invalid request" region gotcha:
  [PREREQUISITES.md §3](PREREQUISITES.md#3-aws-cli-authentication).)

  **B) IAM access keys:**
  ```bash
  aws configure --profile awsha    # paste Access Key ID + Secret; default region eu-central-1
  ```

**Step 2 — log in (SSO only) and select the profile + region for this shell:**

```bash
aws sso login --profile awsha        # SSO only; skip for access keys. Opens a browser to approve.
export AWS_PROFILE=awsha              # = the profile name from step 1
export AWS_REGION=eu-central-1        # Region A. For Region B targets: export AWS_REGION=eu-west-1
```

**Step 3 — verify it works before continuing:**

```bash
aws sts get-caller-identity          # must print your Account/UserId/Arn
```

If that prints your account, you're set. You also need the **Session Manager
plugin** installed (see [PREREQUISITES.md §2](PREREQUISITES.md#2-tools-to-install))
and, for RDP/SSH, the EC2 private key at `~/.ssh/awsha-key.pem` (this is the
`key_name` key pair — adjust the filename if you named yours differently). Every
`start-session` command opens a tunnel that must stay **running** in its own
shell — open a second shell for the RDP/SSH client.

> **Finding instance IDs / IPs — two ways:**
> - From your **deploy clone** (where the Terraform state lives): `terraform output`.
> - From **anywhere** (only needs the CLI + region): look them up by Name tag,
>   shown inline below. Names use your `name_prefix` (default `awsha`) + region
>   letter, e.g. `awsha-a-spoke2-dc`, `awsha-b-fw1`.

---

## 1. Windows domain controller — RDP

The DC is the Windows Server used to manage Active Directory / VPN users.

```bash
# instance ID — either from the deploy clone:
#   DC=$(terraform output -raw dc_instance_id)          # Region A  (dc_instance_id_b = Region B)
# or by tag (works anywhere; -a- = Region A, -b- = Region B):
DC=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=awsha-a-spoke2-dc" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
echo "$DC"

# the Administrator password (decrypted with your EC2 private key)
aws ec2 get-password-data --instance-id "$DC" --priv-launch-key ~/.ssh/awsha-key.pem

# open the RDP tunnel (leave this running; open a second shell for the RDP client)
aws ssm start-session --target "$DC" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3389"],"localPortNumber":["13389"]}'
```

Then point any RDP client at **`localhost:13389`**, user **`Administrator`**, with
the password from `get-password-data`.

> For a **Region B** DC, set `export AWS_REGION=eu-west-1` first and use
> `Values=awsha-b-spoke2-dc` (or `terraform output -raw dc_instance_id_b`).

- `get-password-data` empty → the instance is still generating it; wait a few
  minutes after launch.
- `start-session` → `TargetNotConnected` → the SSM agent hasn't registered yet;
  wait ~1–2 min and check it is `Online`:
  ```bash
  aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$DC" \
    --query 'InstanceInformationList[0].PingStatus' --output text
  ```

**No RDP needed for user management:** create/verify AD users and VPN group
membership headlessly with `aws ssm send-command` — see
[Managing VPN users](DEPLOYMENT.md#managing-vpn-users).

---

## 2. Panorama — web GUI and API

Panorama has no public IP and no SSM agent; reach it through the jump host.

```bash
# jump host instance ID — from the deploy clone:
#   JUMP=$(terraform output -raw ssm_jumphost_instance_id)
# or by tag:
JUMP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=awsha-a-ssm-jumphost" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

# Panorama private IP (default 10.11.0.10; terraform output panorama_private_ip)
PANO=10.11.0.10

# forward Panorama :443 -> localhost:44300 (leave running)
aws ssm start-session --target "$JUMP" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$PANO\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"44300\"]}"
```

Then open **`https://localhost:44300`** (log in with `panorama_admin_password`),
or point the `panos` provider / XML API there. `bash scripts/configure-panorama.sh
tunnel` wraps this exact command.

---

## 3. VM-Series firewall — CLI (SSH)

Same jump-host pattern, to each firewall's management IP on port 22. Firewalls
authenticate with the same EC2 key pair (`key_name`), user `admin`.

```bash
JUMP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=awsha-a-ssm-jumphost" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

# firewall mgmt IPs (defaults; or: terraform output fw_mgmt_private_ips)
#   Region A: fw1 10.10.0.11, fw2 10.10.0.12   |   Region B: fw1 10.20.0.11, fw2 10.20.0.12
FW=10.10.0.11

# forward fw mgmt :22 -> localhost:2211 (leave running)
aws ssm start-session --target "$JUMP" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$FW\"],\"portNumber\":[\"22\"],\"localPortNumber\":[\"2211\"]}"
```

In a second shell:

```bash
ssh -i ~/.ssh/awsha-key.pem -p 2211 admin@localhost
#   e.g.  show high-availability state
#         show global-protect-gateway gateway
```

The jump host has a cross-region route to the Region B firewalls, so the same
command reaches `10.20.0.11` / `.12` (keep `AWS_REGION=eu-central-1` — the jump
host lives in Region A).

---

## Quick reference

| Target | `--document-name` | `--parameters` (host/port) | Local endpoint |
|--------|-------------------|----------------------------|----------------|
| Windows DC (RDP) | `AWS-StartPortForwardingSession` (direct) | `3389` | RDP → `localhost:13389`, user `Administrator` |
| Panorama (GUI/API) | `AWS-StartPortForwardingSessionToRemoteHost` (via jump host) | host=Panorama IP, `443` | `https://localhost:44300` |
| Firewall (SSH) | `AWS-StartPortForwardingSessionToRemoteHost` (via jump host) | host=FW mgmt IP, `22` | `ssh admin@localhost -p 2211` |

---

## Managing VPN users

Creating/removing GlobalProtect users and the `vpnusers` group (over RDP **and**
headless via SSM RunCommand) is documented in
[DEPLOYMENT.md → Managing VPN users](DEPLOYMENT.md#managing-vpn-users).
