# module: panorama_config

Purpose: `panos`-provider resource definitions — template, template stack,
device group, interfaces, zones, virtual router, static routes, NAT + security
policy, and log collector. Also carries the GlobalProtect configuration
(`gp.tf`), gated by `enable_globalprotect`. Consumed by the
`phase2-panorama-config/` workspace.

Resources (panos + XML-API via null_resource / curl):
`panos_panorama_template`, `_template_stack`, `_device_group`,
`_ethernet_interface`, `_management_profile`, `_zone`, `_virtual_router`,
`_static_route_ipv4`, `_nat_rule_ipv4`, `_security_rule`, `_commit`; XML-API for
zone protection, log collector, DLF, and Elasticsearch reinit restart.

Load-bearing:
- **`panos_template_stack` must set `default_vsys`** — without it, PAN-OS
  atomically rejects any commit that assigns a device to the stack, and the
  error only surfaces in the commit-job detail, not the set-config response.
- Management/interface profile permitted-IPs must allow the NLB / health-check
  subnet CIDRs.
- The device-group and template-stack `devices` attributes are set by
  `register-fw-panorama.sh` and guarded with `ignore_changes` so applies do not
  un-assign the firewalls.
- GP objects (tunnel interface, IP pool, gateway, portal, external-gateway list,
  certs, auth) live in `gp.tf`; the network-side gateway tunnel node is created
  via the XML API (`scripts/set-gp-tunnel-node.sh`).
