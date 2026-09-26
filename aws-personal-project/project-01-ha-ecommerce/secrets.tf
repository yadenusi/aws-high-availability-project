# -----------------------------------------------------------------------------
# Secrets
#   - The RDS master password is managed by RDS itself
#     (manage_master_user_password), stored in Secrets Manager and rotated
#     automatically. See database.tf.
#   - The Redis AUTH token is generated here and stored in Secrets Manager.
#   - The CloudFront to ALB origin secret proves a request came through
#     CloudFront. It lives only in CloudFront and the ALB listener rule.
# -----------------------------------------------------------------------------
resource "random_password" "redis_auth" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name                    = "${local.name}/redis-auth-token"
  description             = "AUTH token for the ${local.name} ElastiCache replication group"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = random_password.redis_auth.result
}

resource "random_password" "origin_verify" {
  length  = 40
  special = false
}
