# module: vpc

Purpose: base networking — management VPC, security/transit VPC, and spoke VPCs;
subnets across ≥2 AZs; IGW; NAT gateway(s); route tables; security groups.

AWS resources: `aws_vpc`, `aws_subnet`, `aws_internet_gateway`,
`aws_nat_gateway` + `aws_eip`, `aws_route_table` (+ association),
`aws_security_group`, optional `aws_network_acl`, `aws_vpc_dhcp_options`.

Load-bearing:
- Multi-AZ subnets from day one (HA + multi-region-ready).
- Non-overlapping CIDRs per region (region-parameterized).
- Dedicated subnets per firewall ENI role: mgmt / untrust (public) / trust / HA2.
- A bare `aws_security_group` with no egress block drops AWS's implicit
  allow-all, so this module defaults to allow-all egress when the caller passes
  none.
