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
| `create-ad-test-user.sh` | Create a test AD user after the DC forest is promoted (invoked by Terraform). |
| `fix-drift.sh` | Detect drift between Terraform state and the live Panorama configuration. |
