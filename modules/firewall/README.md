# module: firewall

Purpose: 2× VM-Series in a PAN-OS **Active/Passive HA pair** per region, with
HA2, EIP, source/dest-check disabled on the dataplane, and the IAM instance
profile from the bootstrap module. Placement spans multiple AZs.

AWS resources: `aws_instance` ×2 (VM-Series BYOL AMI, IMDSv2 required,
`user_data` from bootstrap), `aws_network_interface` (mgmt/untrust/trust/HA2 per
firewall, `source_dest_check = false` on dataplane ENIs),
`aws_network_interface_attachment` (device-index order matters → eth0 mgmt,
ethernet1/1 HA2, plus untrust/trust), `aws_eip` + `aws_eip_association` (the
active-firewall public IP / floating-IP analog).

Load-bearing:
- **ENI device-index order = interface naming in PAN-OS.** eth0 is always mgmt;
  `device_index=1` → `ethernet1/1`, which **must** be the HA2 link.
- **`source_dest_check = false`** on dataplane ENIs — mandatory for forwarding.
- **EIP failover** is the floating-IP analog; the HA plugin reassociates it (or
  rewrites the route table) on failover.
- Consumes the vm-auth-key produced in Phase 2a.
