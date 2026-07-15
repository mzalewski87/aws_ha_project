# module: bootstrap

Purpose: render `init-cfg.txt` and deliver it to the firewalls via **EC2
user-data (base64, IMDSv2)**, and create the **IAM role + instance profile** the
firewalls need.

Files: `templates/init-cfg.txt.tpl` — the rendered init-cfg (DNS via the VPC
resolver `.2`, NTP, timezone).

AWS resources: `aws_iam_role`, `aws_iam_instance_profile`, `aws_iam_role_policy`
(HA-plugin EC2 permissions + SSM + optional S3), `local_file` (rendered init-cfg
copies), and optional `aws_s3_bucket` + `aws_s3_object` + `aws_vpc_endpoint`
(S3 gateway) if a bootstrap.xml / content bundle is required.

Load-bearing:
- **HA-plugin IAM**: `ec2:ReplaceRoute`, `ec2:AssociateAddress`,
  `ec2:AssignPrivateIpAddresses`, `ec2:Describe*`, etc. No IAM → no failover.
- **SSM permissions** on the instance profile (for the panos / XML-API tunnel).
- Prefer inline user-data; use S3 only if a content bundle is needed.
- Carries the `vm-auth-key` / `authcodes` /
  `vm-series-auto-registration-pin-*` fields.
