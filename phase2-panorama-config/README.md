# phase2-panorama-config  (SKELETON) — separate `panos` workspace

Purpose: the Phase 2a workspace. Kept separate from root because the `panos`
provider connects to Panorama on **every `plan`** — same load-bearing split as
Azure. Reached via **SSM Session Manager port-forward** (not Bastion).

Ports from Azure: `phase2-panorama-config/` (900+ lines). Steps:
1. Wait for Panorama API (curl loop).
2. Hostname / timezone / NTP / telemetry / statistics (XML-API).
3. Serial + license activation (XML-API).
4. **Generate vm-auth-key** → write `../panorama_vm_auth_key.auto.tfvars`
   (auto-loaded by Phase 1b) — or SSM Parameter Store.
5. panos resources via `module "panorama_config"` (template, DG, interfaces,
   zones, VR(s), routes, NAT, policy) + **GlobalProtect** objects.
6. Zone protection, log collector (disk-pair/DLF/collector-group/ES restart).
7. Final commit + commit-all to FWs.

Providers: `panos` (127.0.0.1:44300 via SSM tunnel) + `null`.

SSM tunnel (replaces Azure Bastion tunnel):
```bash
PANORAMA_ID=$(cd .. && terraform output -raw panorama_instance_id)
aws ssm start-session --target "$PANORAMA_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["localhost"],"portNumber":["443"],"localPortNumber":["44300"]}'
```

TODO: main.tf, providers.tf, variables.tf, outputs.tf. Port from Azure phase2.
