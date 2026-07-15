###############################################################################
# modules/bootstrap — IAM (FW instance profile)
#
# The PAN-OS AWS HA plugin calls the EC2 API to move the EIP / secondary private
# IP and/or rewrite VPC route tables on failover. No instance profile => no
# failover. Permission sets verified against the PAN-OS "IAM roles for HA" doc.
# SSM core is attached so the FW can be reached for automation without a bastion
# (SSM Session Manager, ADR D8).
###############################################################################

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fw" {
  name               = "${var.name_prefix}-fw-ha"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-fw-ha" })
}

# HA-plugin EC2 permissions.
data "aws_iam_policy_document" "ha" {
  # Common to both modes: interface move + describe.
  statement {
    sid = "HaInterfaceAndDescribe"
    actions = [
      "ec2:AttachNetworkInterface",
      "ec2:DetachNetworkInterface",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
    ]
    resources = ["*"]
  }

  # Secondary-IP + EIP move + route-table failover (superset).
  dynamic "statement" {
    for_each = var.ha_failover_mode == "secondary_ip" ? [1] : []
    content {
      sid = "HaSecondaryIpAndEip"
      actions = [
        "ec2:AssignPrivateIpAddresses",
        "ec2:AssociateAddress",
        "ec2:DescribeRouteTables",
      ]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.ha_failover_mode == "secondary_ip" ? [1] : []
    content {
      sid       = "HaReplaceRoute"
      actions   = ["ec2:ReplaceRoute"]
      resources = ["arn:aws:ec2:*:*:route-table/*"]
    }
  }
}

resource "aws_iam_role_policy" "ha" {
  name   = "${var.name_prefix}-fw-ha-plugin"
  role   = aws_iam_role.fw.id
  policy = data.aws_iam_policy_document.ha.json
}

# SSM Session Manager (automation reachability without a bastion, ADR D8).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.fw.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Optional S3 bootstrap read (ADR D7 — only if a bootstrap.xml / content bundle
# is used; default off, inline user-data path).
data "aws_iam_policy_document" "s3" {
  count = var.enable_s3_bootstrap ? 1 : 0
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${var.s3_bootstrap_bucket_arn}/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [var.s3_bootstrap_bucket_arn]
  }
}

resource "aws_iam_role_policy" "s3" {
  count  = var.enable_s3_bootstrap ? 1 : 0
  name   = "${var.name_prefix}-fw-s3-bootstrap"
  role   = aws_iam_role.fw.id
  policy = data.aws_iam_policy_document.s3[0].json
}

resource "aws_iam_instance_profile" "fw" {
  name = "${var.name_prefix}-fw"
  role = aws_iam_role.fw.name
  tags = merge(var.tags, { Name = "${var.name_prefix}-fw" })
}
