# module: panorama

Purpose: self-hosted Panorama on EC2 (BYOL) — central management for all
firewalls across regions.

AWS resources: `aws_instance` (Panorama BYOL AMI, IMDSv2, SSM agent),
`aws_ebs_volume` + `aws_volume_attachment` (log-collection disk),
`aws_network_interface`, `aws_eip` (+ association), an instance profile with SSM
permissions, and `aws_security_group` (mgmt 443 / SSH from mgmt).

Load-bearing:
- The EBS log volume drives the **log-collector disk-pair** config in Phase 2a
  (disk-pair / DLF / collector group / Elasticsearch reinit restart).
- Reachability for the panos / XML-API is via **SSM port-forward**.
- Single Panorama; Panorama HA is not deployed by this module.

Reference: `terraform-aws-swfw-modules/examples/panorama_standalone`.
