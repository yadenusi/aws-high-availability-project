# -----------------------------------------------------------------------------
# AWS Fault Injection Service experiment templates.
# Templates cost nothing until started. Run them with scripts/chaos/run-fis.sh.
#   1. az-web-tier-loss  : terminate every web instance in one AZ
#   2. rds-force-failover: reboot the primary with forced Multi-AZ failover
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "fis_assume" {
  count = var.enable_fis ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "fis" {
  count = var.enable_fis ? 1 : 0

  name               = "${local.name}-fis"
  assume_role_policy = data.aws_iam_policy_document.fis_assume[0].json
}

resource "aws_iam_role_policy_attachment" "fis_ec2" {
  count = var.enable_fis ? 1 : 0

  role       = aws_iam_role.fis[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSFaultInjectionSimulatorEC2Access"
}

resource "aws_iam_role_policy_attachment" "fis_rds" {
  count = var.enable_fis ? 1 : 0

  role       = aws_iam_role.fis[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSFaultInjectionSimulatorRDSAccess"
}

data "aws_iam_policy_document" "fis_logging" {
  count = var.enable_fis ? 1 : 0

  statement {
    sid = "DeliverExperimentLogs"
    actions = [
      "logs:CreateLogDelivery",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "fis_logging" {
  count = var.enable_fis ? 1 : 0

  name   = "experiment-logging"
  role   = aws_iam_role.fis[0].id
  policy = data.aws_iam_policy_document.fis_logging[0].json
}

resource "aws_cloudwatch_log_group" "fis" {
  count = var.enable_fis ? 1 : 0

  name              = "/${local.name}/fis-experiments"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

# 1. Lose the whole web tier in the first AZ.
resource "aws_fis_experiment_template" "az_web_tier_loss" {
  count = var.enable_fis ? 1 : 0

  description = "Terminate every storefront instance in ${local.azs[0]} to simulate losing an AZ"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  target {
    name           = "web-instances-in-az"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"

    resource_tag {
      key   = "aws:autoscaling:groupName"
      value = aws_autoscaling_group.app.name
    }

    filter {
      path   = "Placement.AvailabilityZone"
      values = [local.azs[0]]
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  action {
    name        = "terminate-web-instances"
    action_id   = "aws:ec2:terminate-instances"
    description = "Terminate the targeted instances; the ASG must replace them"

    target {
      key   = "Instances"
      value = "web-instances-in-az"
    }
  }

  log_configuration {
    log_schema_version = 2

    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis[0].arn}:*"
    }
  }

  tags = { Name = "${local.name}-az-web-tier-loss" }

  depends_on = [aws_iam_role_policy_attachment.fis_ec2, aws_iam_role_policy.fis_logging]
}

# 2. Force a Multi-AZ failover of the primary database.
resource "aws_fis_experiment_template" "rds_force_failover" {
  count = var.enable_fis ? 1 : 0

  description = "Reboot the primary RDS instance with forced failover to its standby"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  target {
    name           = "primary-db"
    resource_type  = "aws:rds:db"
    selection_mode = "ALL"
    resource_arns  = [aws_db_instance.primary.arn]
  }

  action {
    name        = "force-failover"
    action_id   = "aws:rds:reboot-db-instances"
    description = "Reboot with failover so the standby becomes the primary"

    parameter {
      key   = "forceFailover"
      value = "true"
    }

    target {
      key   = "DBInstances"
      value = "primary-db"
    }
  }

  log_configuration {
    log_schema_version = 2

    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis[0].arn}:*"
    }
  }

  tags = { Name = "${local.name}-rds-force-failover" }

  depends_on = [aws_iam_role_policy_attachment.fis_rds, aws_iam_role_policy.fis_logging]
}
