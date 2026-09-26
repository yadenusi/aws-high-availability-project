# -----------------------------------------------------------------------------
# CloudTrail: an audit record of every control plane action taken against the
# environment, including the failures injected during testing.
# Multi-region, log file integrity validation, KMS encrypted.
# -----------------------------------------------------------------------------
resource "aws_cloudtrail" "main" {
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.this["cloudtrail"].id
  kms_key_id                    = aws_kms_key.main.arn
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_policy.this]
}
