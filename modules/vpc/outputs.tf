###############################################################################
# modules/vpc — outputs
###############################################################################

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC primary CIDR."
  value       = aws_vpc.this.cidr_block
}

output "igw_id" {
  description = "Internet Gateway ID (null when create_igw = false)."
  value       = try(aws_internet_gateway.this[0].id, null)
}

# Flat map: "<role>-<az_index>" => subnet id (e.g. "mgmt-0").
output "subnet_ids" {
  description = "All subnet IDs keyed by \"<role>-<az_index>\"."
  value       = { for k, s in aws_subnet.this : k => s.id }
}

# Convenience: role => [subnet ids ordered by AZ index].
output "subnet_ids_by_role" {
  description = "Subnet IDs grouped by role, ordered by AZ index."
  value = {
    for role in keys(var.subnets) : role => [
      for i, _ in var.azs : aws_subnet.this["${role}-${i}"].id
    ]
  }
}

# Flat map: "<role>-<az_index>" => route table id. Consumed by the TGW module
# and the Phase 1b routing module to attach TGW / dataplane routes.
output "route_table_ids" {
  description = "Route table IDs keyed by \"<role>-<az_index>\"."
  value       = { for k, rt in aws_route_table.this : k => rt.id }
}

output "route_table_ids_by_role" {
  description = "Route table IDs grouped by role, ordered by AZ index."
  value = {
    for role in keys(var.subnets) : role => [
      for i, _ in var.azs : aws_route_table.this["${role}-${i}"].id
    ]
  }
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs keyed by AZ index (empty when create_nat = false)."
  value       = { for k, ngw in aws_nat_gateway.this : k => ngw.id }
}

output "security_group_ids" {
  description = "Security group IDs keyed by the short name from var.security_groups."
  value       = { for k, sg in aws_security_group.this : k => sg.id }
}
