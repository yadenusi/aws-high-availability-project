# -----------------------------------------------------------------------------
# EC2 instance role for the web tier
#   - Session Manager access (no SSH keys, no port 22)
#   - CloudWatch agent (memory, disk, nginx and app logs)
#   - Read the app bundle, the RDS managed secret and the Redis AUTH secret
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.name}-app-instance"
  description        = "Web tier instances of ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "app_cw_agent" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ReadAppBundle"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this["artifacts"].arn}/app/*"]
  }

  statement {
    sid     = "ReadRuntimeSecrets"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      aws_db_instance.primary.master_user_secret[0].secret_arn,
      aws_secretsmanager_secret.redis_auth.arn,
    ]
  }

  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "storefront-runtime"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-app-instance"
  role = aws_iam_role.app.name
}

# -----------------------------------------------------------------------------
# RDS enhanced monitoring role
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "rds_monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name               = "${local.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
