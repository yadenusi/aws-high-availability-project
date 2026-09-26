provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "Terraform"
      Capstone    = "SAA-C03 Project 1"
      Stack       = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  bucket_name = "${var.project_name}-tfstate-${var.project_code}-${local.account_id}"
}

# -----------------------------------------------------------------------------
# Customer managed KMS key that encrypts the state file at rest.
# State can hold ARNs, resource IDs and generated passwords, so it gets its own
# key with rotation turned on rather than the default S3 managed key.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "state_key" {
  # Key policies are resource policies: "*" means this key only.
  #checkov:skip=CKV_AWS_109:Key policy resource "*" refers to this key
  #checkov:skip=CKV_AWS_111:Key policy resource "*" refers to this key
  #checkov:skip=CKV_AWS_356:Key policy resource "*" refers to this key

  statement {
    sid       = "EnableAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowS3UseForStateBucketOnly"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "${var.project_name} ${var.project_code} Terraform state encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.state_key.json
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.project_name}-${var.project_code}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

# -----------------------------------------------------------------------------
# State bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18:Access to state is audited by CloudTrail; a separate log bucket per state bucket is not justified
  #checkov:skip=CKV_AWS_144:State is versioned and KMS encrypted; cross-region replication is not needed for a lab

  bucket        = local.bucket_name
  force_destroy = false

  lifecycle {
    # Losing this bucket means losing track of every resource in the project.
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyUploadsWithoutTheStateKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.state.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# -----------------------------------------------------------------------------
# Write the backend settings for the main stack so nothing is typed by hand.
# -----------------------------------------------------------------------------
resource "local_file" "backend_config" {
  filename        = "${path.module}/../backend.hcl"
  file_permission = "0644"
  content         = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    key          = "${var.state_key}"
    region       = "${var.aws_region}"
    encrypt      = true
    kms_key_id   = "${aws_kms_key.state.arn}"
    use_lockfile = true
  EOT
}
