# scripts

Bash orchestrators for the phases that Terraform cannot express directly —
mostly PAN-OS device-local config and licensing, reached over an **SSM Session
Manager port-forward** to Panorama or the firewalls. Some are invoked by
Terraform (`terraform_data` / `null_resource` local-exec); others are run by
hand at a specific phase.

| Script | Purpose |
|--------|---------|
| `accept-marketplace-terms.sh` | Subscribe the account to the VM-Series + Panorama BYOL AMIs (one-time per account). |
| `activate-panorama.sh` | Phase 2a — set Panorama's serial, fetch its management license, and fetch the device certificate via a CSP OTP. |
| `set-panorama-password.sh` | Set the Panorama admin password over SSH (EC2/PAN-OS has no admin-password injection field). |
| `check-panorama.sh` | Poll the Panorama API for readiness/health. |
| `configure-panorama.sh` | Phase 2a orchestrator — SSM tunnel, hostname/serial/license, vm-auth-key; commit jobs are polled to completion. |
| `generate-vm-auth-key.sh` | Generate a vm-auth-key and write `../panorama_vm_auth_key.auto.tfvars` for Phase 1b. |
| `register-fw-panorama.sh` | Phase 2b — read the firewall serials, add them to Panorama, set device-group / template-stack membership, and `commit-all`. |
| `configure-ha.sh` | Configure native PAN-OS Active/Passive HA (Setup/Election/Control-Link/Data-Link) per firewall over SSH — not covered by the panos provider. |
| `failover-test.sh` | Resilience test harness (HA and region-failure scenarios), each with `down`/`up`/`status`, using only the AWS API. |
| `setup-log-collector.sh` | Phase 2a — add the EBS log volume to Panorama's logging disk-pair, configure DLF / collector group, and reinit Elasticsearch. |
| `set-untrust-overrides.sh` | Phase 2a — set the per-device value of the untrust-primary template variable, one override per firewall serial, via the XML API. |
| `set-gp-tunnel-node.sh` | Phase GP — create the network-side GlobalProtect gateway tunnel node (`network/tunnel/global-protect-gateway`) via the XML API. |
| `set-gp-local-users.sh` | Phase GP — create GlobalProtect local users with a properly hashed password. |
| `deploy-gp-client.sh` | Phase GP — download and activate the GlobalProtect agent package on each firewall so the portal can serve the installer. |
| `scm-lib.sh` | Path B — shared helpers (cached OAuth token, hard-failing API calls, job polling). Source it. |
| `scm-onboard-fw.sh` | Path B — wait for the firewalls to connect to SCM, move them into the folder, emit per-device tfvars (replaces `register-fw-panorama.sh`). |
| `scm-ha.sh` | Path B — configure native Active/Passive HA from SCM (`/ha-configurations`); replaces `configure-ha.sh`. |
| `scm-push.sh` | Path B — push the folder's candidate config and wait for the job; a non-OK job fails the script. |
| `scm-verify.sh` | Path B — read-only report: devices, HA state, security-rule order. |
| `scm-gp-local.sh` | Path B — GlobalProtect portal + gateway (+ tunnel node, pool, DNS, Let's Encrypt cert) in the device-LOCAL config, `admin`/`build`/`letsencrypt`/`content`/`cleanup` (`content` installs Apps+Threats + Antivirus, needed before IP Defense on a fresh unit); run on EACH unit (local config does not replicate between SCM-managed peers). |
| `scm-upgrade.sh` | Path B — in-place PAN-OS upgrade of a folder through an SCM upgrade rule + schedule; waits until every unit runs the version and every pair is active/passive, always removes its schedule. |
| `scm-folder-release.sh` | Path B — move devices out of the folder: all of them (teardown, so `phase2-scm-config` can be destroyed) or only the listed disconnected serials (after a firewall rebuild). |
| `panel-setup.sh` | Path B panel — `ad`: AD groups `panel-admins` / `panel-operators` (+ members) on the DC via SSM; `fw`: restricted firewall admin `panelro` (role `panel-ro`, XML-API op commands only) on each unit. |
| `guacamole-ldap-setup.sh` | Both paths — Guacamole AD sign-in (`guac_ldap_enabled`): AD group `guacusers` (+ members) and bind account `svc-guacamole` with the generated password from the Guacamole secret, on the DC via SSM. Re-run after the Guacamole host is replaced. |
| `setup-pki.sh` | Two-tier AD CS PKI (offline root + enterprise issuing CA) over SSM RunCommand; publishes the root to AD and verifies it. |
| `setup-machine-autoenroll.sh` | Machine-certificate autoenrollment policy in the domain (GP pre-logon prerequisite). |
| `create-ad-test-user.sh` | Create a test AD user after the DC forest is promoted (invoked by Terraform). |
| `fix-drift.sh` | Detect drift between Terraform state and the live Panorama configuration. |
