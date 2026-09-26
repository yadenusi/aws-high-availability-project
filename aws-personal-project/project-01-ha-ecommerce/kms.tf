# -----------------------------------------------------------------------------
# Customer managed key for the stack (us-east-2): RDS storage, RDS managed
# secret, ElastiCache at rest, Secrets Manager, CloudWatch Logs, SNS, CloudTrail.
# -----------------------------------------------------------------------------
locals {
  trail_name = "${local.name}-trail"
  trail_arn  = "arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${local.trail_name}"
}

data "aws_iam_policy_document" "kms_main" {
  # Key policies are resource policies: "*" means this key only.
  #checkov:skip=CKV_AWS_109:Key policy resource "*" refers to this key
  #checkov:skip=CKV_AWS_111:Key policy resource "*" refers to this key
  #checkov:skip=CKV_AWS_356:Key policy resource "*" refers to this key

  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid = "CloudWatchLogsEncryption"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }

  statement {
    sid       = "ServicesPublishingToEncryptedSns"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]

    principals {
      type = "Service"
      identifiers = [
        "cloudwatch.amazonaws.com",
        "events.amazonaws.com",
        "events.rds.amazonaws.com",
        "elasticache.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "CloudTrailEncryptLogs"
    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${local.partition}:cloudtrail:*:${local.account_id}:trail/*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "CloudTrailDescribeKey"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "main" {
  description             = "${local.name} data, logs and notifications"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_main.json
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}

# -----------------------------------------------------------------------------
# Key in us-east-1 for the SNS topic that CloudFront alarms publish to.
# CloudWatch cannot publish to a topic encrypted with the AWS managed SNS key,
# so a customer managed key is required there too.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "kms_edge" {
  # Key policies are resource policies: "*" means this key only.
  #checkov:skip=CKV_AWS_109:Key policy resource "*" refers to this key
  #checkov:skip=CKV_AWS_111:Key policy resource "*" refers to this key
  #checkov:skip=CKV_AWS_356:Key policy resource "*" refers to this key

  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarmsToSns"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "edge" {
  provider = aws.us_east_1

  description             = "${local.name} CloudFront alarm notifications"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_edge.json
}

resource "aws_kms_alias" "edge" {
  provider = aws.us_east_1

  name          = "alias/${local.name}-edge"
  target_key_id = aws_kms_key.edge.key_id
}
