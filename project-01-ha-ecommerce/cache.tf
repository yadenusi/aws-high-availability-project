# -----------------------------------------------------------------------------
# ElastiCache Redis OSS replication group
# One primary plus replicas spread across AZs, automatic failover, Multi-AZ,
# encryption in transit (TLS) and at rest (KMS), AUTH token required.
# -----------------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "main" {
  name        = "${local.name}-cache"
  description = "Data tier subnets for ${local.name}"
  subnet_ids  = [for s in aws_subnet.data : s.id]
}

resource "aws_elasticache_parameter_group" "redis" {
  name        = "${local.name}-redis7"
  family      = "redis7"
  description = "Storefront cache: evict least recently used keys when memory is full"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
}

resource "aws_cloudwatch_log_group" "redis_slowlog" {
  name              = "/${local.name}/elasticache/slow-log"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${local.name}-redis"
  description          = "Storefront cache for ${local.name}"

  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = var.redis_node_type
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.redis.name
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.cache.id]

  num_cache_clusters          = var.redis_num_cache_clusters
  preferred_cache_cluster_azs = [for i in range(var.redis_num_cache_clusters) : local.azs[i % length(local.azs)]]
  automatic_failover_enabled  = true
  multi_az_enabled            = true

  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.main.arn
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result

  snapshot_retention_limit   = 3
  snapshot_window            = "05:00-06:00"
  maintenance_window         = "sun:06:30-sun:07:30"
  auto_minor_version_upgrade = true
  apply_immediately          = false

  # Failover, node replacement and maintenance events go to the alerts topic.
  notification_topic_arn = aws_sns_topic.alerts.arn

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis_slowlog.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }
}
