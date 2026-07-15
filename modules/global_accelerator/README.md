# module: global_accelerator

Purpose: AWS Global Accelerator as the resilient global front-end for the
GlobalProtect **Portal** — anycast IPs with cross-region, health-checked
failover. Used in the multi-region deployment.

AWS resources: `aws_globalaccelerator_accelerator`,
`aws_globalaccelerator_listener` (TCP 443), `aws_globalaccelerator_endpoint_group`
per region (endpoints = the per-region portal EIPs), with health checks.

Load-bearing:
- Fronts the **Portal only** — gateways rely on GP-native failover.
- Gated by a feature flag / count so it does not deploy until Region B exists.
