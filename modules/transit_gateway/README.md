# module: transit_gateway

Purpose: AWS Transit Gateway as the centralized hub — attaches the security VPC
and spoke VPCs and forces spoke↔spoke and spoke↔internet traffic through the
firewalls.

AWS resources: `aws_ec2_transit_gateway`,
`aws_ec2_transit_gateway_vpc_attachment` (security-VPC attachment with
**`appliance_mode_support = "enable"`**), `aws_ec2_transit_gateway_route_table`,
`aws_ec2_transit_gateway_route`,
`aws_ec2_transit_gateway_route_table_association` / `_propagation`.

Load-bearing:
- **`appliance_mode_support = enable`** on the security-VPC attachment —
  mandatory for cross-AZ flow symmetry through the firewalls.
- TGW route tables define which flows transit the firewalls (inspection vs
  bypass).

Reference: `terraform-aws-swfw-modules/modules/transit_gateway`,
`examples/centralized_design`.
