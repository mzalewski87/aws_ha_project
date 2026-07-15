# module: spoke1_app

Purpose: an Apache "hello world" app on EC2 in a spoke VPC — proves inbound
DNAT, outbound SNAT, and east-west traffic through the firewalls.

AWS resources: `aws_instance` (Ubuntu, user-data cloud-init),
`aws_network_interface`, security group, EBS root.

Load-bearing:
- **cloud-init retry loop** (a systemd unit retrying every 60s): the spoke's
  outbound depends on the Phase 2b firewall rules being live, so package installs
  must retry rather than run once at first boot.
- Static private IP so firewall DNAT / security rules can reference it.
