# module: spoke2_dc

Purpose: a Windows Server EC2 instance in a spoke VPC, prepared for AD DS
promotion (promotion itself lives in `optional/dc-promote/`).

AWS resources: `aws_instance` (Windows AMI), `aws_network_interface`, security
group, EBS root, key pair / password via SSM.

Load-bearing:
- Static private IP; DNS considerations for AD.
- Promotion via `optional/dc-promote/` (SSM RunCommand / user-data PowerShell).
