# Accessing the environment (RDP / Panorama / firewall CLI)

Nothing in this environment has a public management IP and there is **no
bastion** — every management plane is reached through **AWS SSM Session Manager**
(no inbound ports opened). There are two patterns:

- **Windows domain controller** — has its own SSM agent, so you port-forward
  **directly** to the instance.
- **Panorama and the VM-Series firewalls** — PAN-OS runs no SSM agent, so you
  port-forward **through the SSM jump host** to the target's private IP
  (an SSM *RemoteHost* forward).

**Prerequisites:** AWS CLI v2 + the **Session Manager plugin** installed and a
valid AWS login (see [PREREQUISITES.md](PREREQUISITES.md)); the EC2 private key
at `~/.ssh/<key_name>.pem`; and run the commands from your deploy clone so
`terraform output` resolves the instance IDs/IPs. Keep each `start-session`
command **running** in its own shell while you're connected.

> Quick reference:
>
> | Target | Connect with | Local endpoint |
> |--------|--------------|----------------|
> | Windows DC (RDP) | `AWS-StartPortForwardingSession` :3389 → direct to the DC | `localhost:13389` (RDP client) |
> | Panorama (web GUI / API) | `...RemoteHost` :443 → via jump host | `https://localhost:44300` |
> | VM-Series firewall (SSH CLI) | `...RemoteHost` :22 → via jump host | `ssh admin@localhost -p 2211` |

---

## 1. Windows domain controller — RDP

The DC (and the Region B replica DC) is the Windows Server used to manage Active
Directory / test users. It connects **directly** (its own SSM agent).

```bash
# instance ID (Region A DC; use dc_instance_id_b for the Region B replica)
DC=$(terraform output -raw dc_instance_id)

# one-time: the Administrator password (decrypted with your EC2 private key)
aws ec2 get-password-data --instance-id "$DC" \
  --priv-launch-key ~/.ssh/<key_name>.pem

# open the RDP tunnel (keep this shell running)
aws ssm start-session --target "$DC" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3389"],"localPortNumber":["13389"]}'
```

Then point any RDP client at **`localhost:13389`**, user **`Administrator`**, with
the password from `get-password-data`.

- If `get-password-data` returns empty, the instance is still generating it —
  wait a few minutes after launch.
- If `start-session` fails with `TargetNotConnected`, the SSM agent hasn't
  registered yet (or the instance lacks its IAM instance profile) — wait ~1–2 min
  and check `aws ssm describe-instance-information --filters
  "Key=InstanceIds,Values=$DC" --query 'InstanceInformationList[0].PingStatus'`
  reads `Online`.

**No RDP needed for user management:** you can create/verify AD users and VPN
group membership headlessly with `aws ssm send-command` — see
[Managing VPN users](DEPLOYMENT.md#managing-vpn-users).

---

## 2. Panorama — web GUI and API

Panorama has no public IP and no SSM agent; reach it through the jump host.

```bash
JUMP=$(terraform output -raw ssm_jumphost_instance_id)
PANO=$(terraform output -raw panorama_private_ip)

aws ssm start-session --target "$JUMP" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$PANO\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"44300\"]}"
```

Then open **`https://localhost:44300`** in a browser (log in with
`panorama_admin_password`), or point the `panos` provider / XML API at it.
`bash scripts/configure-panorama.sh tunnel` wraps this exact command.

---

## 3. VM-Series firewall — CLI (SSH)

Same jump-host pattern, to each firewall's management IP on port 22. Firewalls
authenticate with the same EC2 key pair (`key_name`).

```bash
JUMP=$(terraform output -raw ssm_jumphost_instance_id)
terraform output fw_mgmt_private_ips     # e.g. region_a fw1 = 10.10.0.11, fw2 = 10.10.0.12

# forward fw1 mgmt :22 -> localhost:2211 (keep running)
aws ssm start-session --target "$JUMP" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["10.10.0.11"],"portNumber":["22"],"localPortNumber":["2211"]}' &

# in another shell:
ssh -i ~/.ssh/<key_name>.pem -p 2211 admin@localhost
#   e.g.  show high-availability state
#         show global-protect-gateway gateway
```

Region B firewalls (`10.20.0.11` / `.12`) are reachable the same way — the jump
host has a cross-region route to them.

---

## 4. Managing VPN users

Creating/removing GlobalProtect users and the `vpnusers` group (both over RDP and
headless via SSM RunCommand) is documented in
[DEPLOYMENT.md → Managing VPN users](DEPLOYMENT.md#managing-vpn-users).
