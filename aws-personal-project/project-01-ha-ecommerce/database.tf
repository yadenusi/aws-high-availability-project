# -----------------------------------------------------------------------------
# RDS MySQL
#   primary : Multi-AZ (synchronous standby in another AZ, automatic failover)
#   replica : asynchronous read replica that offloads read traffic
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name        = "${local.name}-db"
  description = "Data tier subnets for ${local.name}"
  subnet_ids  = [for s in aws_subnet.data : s.id]
}

resource "aws_db_parameter_group" "mysql" {
  name_prefix = "${local.name}-mysql80-"
  family      = "mysql8.0"
  description = "Storefront MySQL settings: TLS required, utf8mb4, slow query log"

  parameter {
    name  = "require_secure_transport"
    value = "1"
  }

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_0900_ai_ci"
  }

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Pre-create the log groups RDS exports to, so they get KMS encryption and retention.
resource "aws_cloudwatch_log_group" "rds" {
  for_each = toset(flatten([
    for id in ["${local.name}-mysql", "${local.name}-mysql-replica"] : [
      "/aws/rds/instance/${id}/error",
      "/aws/rds/instance/${id}/slowquery",
    ]
  ]))

  name              = each.key
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "random_id" "final_snapshot" {
  byte_length = 4
}

resource "aws_db_instance" "primary" {
  identifier     = "${local.name}-mysql"
  engine         = "mysql"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = "storefront"
  username = "storefront_admin"

  # RDS generates the password, stores it in Secrets Manager and rotates it.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.main.arn

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.mysql.name
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  storage_type          = "gp3"
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.main.arn

  backup_retention_period  = var.db_backup_retention_days
  backup_window            = "03:00-04:00"
  maintenance_window       = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = true

  auto_minor_version_upgrade = true
  apply_immediately          = false

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  performance_insights_enabled    = var.db_performance_insights
  performance_insights_kms_key_id = var.db_performance_insights ? aws_kms_key.main.arn : null

  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.name}-mysql-final-${random_id.final_snapshot.hex}"

  depends_on = [
    aws_cloudwatch_log_group.rds,
    aws_iam_role_policy_attachment.rds_monitoring,
  ]
}

resource "aws_db_instance" "replica" {
  #checkov:skip=CKV_AWS_157:The replica scales reads; write availability comes from the Multi-AZ primary
  #checkov:skip=CKV_AWS_133:The replica is rebuilt from the primary, which keeps 7 days of backups

  identifier          = "${local.name}-mysql-replica"
  replicate_source_db = aws_db_instance.primary.identifier
  instance_class      = var.db_instance_class

  # Place the replica in a different AZ from the first AZ for read resilience.
  availability_zone      = local.azs[1]
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.mysql.name
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  storage_type          = "gp3"
  max_allocated_storage = var.db_max_allocated_storage
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.main.arn

  backup_retention_period = 0
  multi_az                = false
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = false

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  performance_insights_enabled    = var.db_performance_insights
  performance_insights_kms_key_id = var.db_performance_insights ? aws_kms_key.main.arn : null

  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  deletion_protection = var.db_deletion_protection
  skip_final_snapshot = true
}
