# module: routing

Purpose: VPC route tables that steer spoke and return traffic through the
firewalls / Transit Gateway.

AWS resources: `aws_route_table`, `aws_route` (0.0.0.0/0 → NAT / firewall / TGW;
east-west → TGW), `aws_route_table_association`.

Load-bearing:
- Spoke default and east-west routes point at the TGW; security-VPC routes point
  at the firewall trust ENI. Flow symmetry is guaranteed by TGW **appliance
  mode** (see the transit_gateway module).
- Keep routes explicit — no BGP propagation surprises.
