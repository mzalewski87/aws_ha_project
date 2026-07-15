# module: globalprotect

GlobalProtect is configured in the **panos workspace**, not as an aws-provider
Terraform module: see `modules/panorama_config/gp.tf` (portal, gateway, tunnel
interface, SSL/TLS + cert, auth profile, IP pool, external-gateway list), gated
by `enable_globalprotect`. Design: `docs/globalprotect-design.md`. This
directory is kept only as a pointer.
