# -----------------------------------------------------------------------------
# Buckets
#   assets     : static storefront files, read only by CloudFront through OAC
#   artifacts  : application bundle pulled by instances at boot
#   logs       : ALB access logs (alb/) and S3 server access logs (s3-access/)
#   cloudtrail : CloudTrail log files
# All use SSE-S3 (ALB and S3 log delivery support only SSE-S3). CloudTrail
# files are additionally encrypted with the stack KMS key at the trail level.
# -----------------------------------------------------------------------------
locals {
  buckets = {
    assets     = { expire_days = 0 }
    artifacts  = { expire_days = 0 }
    logs       = { expire_days = 90 }
    cloudtrail = { expire_days = 365 }
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  # Checkov cannot link the for_each companion resources below back to these
  # buckets, so it reports them missing. They are all defined in this file.
  #checkov:skip=CKV2_AWS_6:Public access block is aws_s3_bucket_public_access_block.this (for_each)
  #checkov:skip=CKV_AWS_21:Versioning is aws_s3_bucket_versioning.this (for_each)
  #checkov:skip=CKV2_AWS_61:Lifecycle is aws_s3_bucket_lifecycle_configuration.this (for_each)
  #checkov:skip=CKV_AWS_18:Access logging is aws_s3_bucket_logging.this; the logs bucket cannot log to itself

  bucket        = "${local.name}-${each.key}-${local.account_id}"
  force_destroy = var.force_destroy_buckets

  tags = { Name = "${local.name}-${each.key}" }
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    id     = "housekeeping"
    status = "Enabled"

    filter {}

    dynamic "expiration" {
      for_each = local.buckets[each.key].expire_days > 0 ? [1] : []
      content {
        days = local.buckets[each.key].expire_days
      }
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# Server access logs for every bucket except the log bucket itself.
resource "aws_s3_bucket_logging" "this" {
  for_each = { for k, v in aws_s3_bucket.this : k => v if k != "logs" }

  bucket        = each.value.id
  target_bucket = aws_s3_bucket.this["logs"].id
  target_prefix = "s3-access/${each.key}/"

  depends_on = [aws_s3_bucket_policy.this]
}

# -----------------------------------------------------------------------------
# Bucket policies
# The assets policy is a separate resource on purpose: it references the
# CloudFront distribution, which references the ALB, which needs the logs
# policy in place first. Keeping them apart avoids a dependency cycle.
# -----------------------------------------------------------------------------
data "aws_elb_service_account" "main" {}

# Every bucket: deny any request that is not over TLS.
data "aws_iam_policy_document" "tls_only" {
  for_each = local.buckets

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this[each.key].arn,
      "${aws_s3_bucket.this[each.key].arn}/*",
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
}

# logs: the regional ELB account writes ALB logs under alb/, and the S3
# logging service writes server access logs under s3-access/.
data "aws_iam_policy_document" "logs" {
  source_policy_documents = [data.aws_iam_policy_document.tls_only["logs"].json]

  statement {
    sid       = "AllowAlbLogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this["logs"].arn}/alb/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
  }

  statement {
    sid       = "AllowS3ServerAccessLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this["logs"].arn}/s3-access/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# cloudtrail: standard delivery permissions, scoped to this trail only.
data "aws_iam_policy_document" "cloudtrail" {
  source_policy_documents = [data.aws_iam_policy_document.tls_only["cloudtrail"].json]

  statement {
    sid       = "AllowCloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.this["cloudtrail"].arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "AllowCloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this["cloudtrail"].arn}/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

locals {
  bucket_policies = {
    artifacts  = data.aws_iam_policy_document.tls_only["artifacts"].json
    logs       = data.aws_iam_policy_document.logs.json
    cloudtrail = data.aws_iam_policy_document.cloudtrail.json
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = local.bucket_policies

  bucket = aws_s3_bucket.this[each.key].id
  policy = each.value

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# assets: CloudFront reads objects through Origin Access Control.
data "aws_iam_policy_document" "assets" {
  source_policy_documents = [data.aws_iam_policy_document.tls_only["assets"].json]

  statement {
    sid       = "AllowCloudFrontOacRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this["assets"].arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "assets" {
  bucket = aws_s3_bucket.this["assets"].id
  policy = data.aws_iam_policy_document.assets.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# -----------------------------------------------------------------------------
# Content
# -----------------------------------------------------------------------------
# Static files served by CloudFront at /static/*
resource "aws_s3_object" "static" {
  for_each = fileset(local.static_dir, "**")

  bucket       = aws_s3_bucket.this["assets"].id
  key          = "static/${each.value}"
  source       = "${local.static_dir}/${each.value}"
  etag         = filemd5("${local.static_dir}/${each.value}")
  content_type = lookup(local.static_content_types, reverse(split(".", each.value))[0], "application/octet-stream")

  cache_control = "public, max-age=86400"
}

# Application bundle. Its hash is baked into user data, so a code change
# creates a new launch template version and the ASG instance refresh rolls it out.
data "archive_file" "app" {
  type        = "zip"
  source_dir  = "${path.module}/app"
  output_path = "${path.module}/build/app.zip"
  excludes    = ["static/**", "__pycache__/**", "**/*.pyc", ".venv/**"]
}

resource "aws_s3_object" "app_bundle" {
  bucket = aws_s3_bucket.this["artifacts"].id
  key    = "app/storefront-${data.archive_file.app.output_md5}.zip"
  source = data.archive_file.app.output_path
  etag   = data.archive_file.app.output_md5
}
