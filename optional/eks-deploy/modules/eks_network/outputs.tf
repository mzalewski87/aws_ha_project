output "vpc_id" { value = aws_vpc.this.id }
output "node_subnet_ids" { value = [for s in aws_subnet.node : s.id] }
output "attachment_id" { value = aws_ec2_transit_gateway_vpc_attachment.this.id }
output "vpc_cidr" { value = aws_vpc.this.cidr_block }
