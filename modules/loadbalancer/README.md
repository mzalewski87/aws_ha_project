# module: loadbalancer

Purpose: **NLB for the inbound app (Apache/WordPress) path only**. Not for
GlobalProtect (GP uses an EIP + GP-native gateway failover).

AWS resources: `aws_lb` (type=network), `aws_lb_target_group` (target_type=ip →
firewall untrust IPs), `aws_lb_listener`, `aws_lb_target_group_attachment`, with
health checks.

Load-bearing:
- Keep firewall **DNAT** matching the NLB/EIP address so inbound resolves to the
  app; SNAT to trust to avoid asymmetric routing.
- Health-check source = NLB subnets → allow in the management/interface profile.
