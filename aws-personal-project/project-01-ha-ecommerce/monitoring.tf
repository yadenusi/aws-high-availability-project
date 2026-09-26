# =============================================================================
# Notifications
# =============================================================================
resource "aws_sns_topic" "alerts" {
  name              = "${local.name}-alerts"
  display_name      = "Storefront alerts"
  kms_master_key_id = aws_kms_key.main.arn
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid = "AccountOwnerManage"
    actions = [
      "SNS:GetTopicAttributes",
      "SNS:SetTopicAttributes",
      "SNS:AddPermission",
      "SNS:RemovePermission",
      "SNS:DeleteTopic",
      "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish",
    ]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "AwsServicesPublish"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

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
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

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

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# CloudFront metrics exist only in us-east-1, so its alarm needs a topic there.
resource "aws_sns_topic" "edge_alerts" {
  provider = aws.us_east_1

  name              = "${local.name}-edge-alerts"
  display_name      = "Storefront CDN alerts"
  kms_master_key_id = aws_kms_key.edge.arn
}

resource "aws_sns_topic_subscription" "edge_alerts_email" {
  provider = aws.us_east_1

  topic_arn = aws_sns_topic.edge_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# =============================================================================
# CloudWatch alarms (us-east-2)
# =============================================================================
locals {
  # tomap() keeps every dims value the same type so the alarm map is uniform.
  alb_dims = tomap({ LoadBalancer = aws_lb.main.arn_suffix })
  tg_dims = tomap({
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  })
  asg_dims     = tomap({ AutoScalingGroupName = aws_autoscaling_group.app.name })
  primary_dims = tomap({ DBInstanceIdentifier = aws_db_instance.primary.identifier })
  replica_dims = tomap({ DBInstanceIdentifier = aws_db_instance.replica.identifier })

  # ElastiCache names member nodes <group>-001, <group>-002 ...
  redis_nodes = [
    for i in range(var.redis_num_cache_clusters) :
    format("%s-%03d", aws_elasticache_replication_group.main.replication_group_id, i + 1)
  ]

  alarms = merge(
    {
      alb-elb-5xx = {
        description = "The load balancer itself is returning 5xx errors (no healthy targets or overload)."
        namespace   = "AWS/ApplicationELB", metric = "HTTPCode_ELB_5XX_Count", stat = "Sum"
        dims        = local.alb_dims, op = "GreaterThanOrEqualToThreshold", threshold = 10
        period      = 60, evals = 5, datapoints = 3, missing = "notBreaching"
      }
      alb-target-5xx = {
        description = "Application instances are returning 5xx errors."
        namespace   = "AWS/ApplicationELB", metric = "HTTPCode_Target_5XX_Count", stat = "Sum"
        dims        = local.tg_dims, op = "GreaterThanOrEqualToThreshold", threshold = 10
        period      = 60, evals = 5, datapoints = 3, missing = "notBreaching"
      }
      alb-unhealthy-hosts = {
        description = "At least one target is failing ALB health checks."
        namespace   = "AWS/ApplicationELB", metric = "UnHealthyHostCount", stat = "Maximum"
        dims        = local.tg_dims, op = "GreaterThanOrEqualToThreshold", threshold = 1
        period      = 60, evals = 2, datapoints = 2, missing = "notBreaching"
      }
      alb-healthy-below-min = {
        description = "Fewer healthy targets than the Auto Scaling minimum."
        namespace   = "AWS/ApplicationELB", metric = "HealthyHostCount", stat = "Minimum"
        dims        = local.tg_dims, op = "LessThanThreshold", threshold = var.asg_min_size
        period      = 60, evals = 3, datapoints = 3, missing = "breaching"
      }
      alb-latency-p95 = {
        description = "95th percentile response time is above 1 second."
        namespace   = "AWS/ApplicationELB", metric = "TargetResponseTime", stat = "p95"
        dims        = local.tg_dims, op = "GreaterThanThreshold", threshold = 1
        period      = 60, evals = 5, datapoints = 3, missing = "notBreaching"
      }
      asg-cpu-high = {
        description = "Web tier CPU is above 80 percent even after scaling; check max size."
        namespace   = "AWS/EC2", metric = "CPUUtilization", stat = "Average"
        dims        = local.asg_dims, op = "GreaterThanThreshold", threshold = 80
        period      = 60, evals = 10, datapoints = 8, missing = "notBreaching"
      }
      asg-in-service-below-min = {
        description = "In-service instances dropped below the Auto Scaling minimum."
        namespace   = "AWS/AutoScaling", metric = "GroupInServiceInstances", stat = "Minimum"
        dims        = local.asg_dims, op = "LessThanThreshold", threshold = var.asg_min_size
        period      = 60, evals = 5, datapoints = 5, missing = "breaching"
      }
      rds-primary-cpu = {
        description = "Primary database CPU is above 80 percent."
        namespace   = "AWS/RDS", metric = "CPUUtilization", stat = "Average"
        dims        = local.primary_dims, op = "GreaterThanThreshold", threshold = 80
        period      = 300, evals = 3, datapoints = 3, missing = "notBreaching"
      }
      rds-primary-free-storage = {
        description = "Primary database has less than 2 GiB of free storage."
        namespace   = "AWS/RDS", metric = "FreeStorageSpace", stat = "Minimum"
        dims        = local.primary_dims, op = "LessThanThreshold", threshold = 2147483648
        period      = 300, evals = 1, datapoints = 1, missing = "notBreaching"
      }
      rds-primary-freeable-memory = {
        description = "Primary database has less than 100 MB of freeable memory."
        namespace   = "AWS/RDS", metric = "FreeableMemory", stat = "Minimum"
        dims        = local.primary_dims, op = "LessThanThreshold", threshold = 104857600
        period      = 300, evals = 3, datapoints = 3, missing = "notBreaching"
      }
      rds-primary-connections = {
        description = "Primary database connections are close to the instance limit."
        namespace   = "AWS/RDS", metric = "DatabaseConnections", stat = "Maximum"
        dims        = local.primary_dims, op = "GreaterThanThreshold", threshold = 50
        period      = 60, evals = 5, datapoints = 3, missing = "notBreaching"
      }
      rds-replica-lag = {
        description = "Read replica is more than 30 seconds behind the primary."
        namespace   = "AWS/RDS", metric = "ReplicaLag", stat = "Maximum"
        dims        = local.replica_dims, op = "GreaterThanThreshold", threshold = 30
        period      = 60, evals = 5, datapoints = 3, missing = "notBreaching"
      }
      rds-replica-cpu = {
        description = "Read replica CPU is above 80 percent."
        namespace   = "AWS/RDS", metric = "CPUUtilization", stat = "Average"
        dims        = local.replica_dims, op = "GreaterThanThreshold", threshold = 80
        period      = 300, evals = 3, datapoints = 3, missing = "notBreaching"
      }
    },
    merge([
      for node in local.redis_nodes : {
        "redis-${node}-engine-cpu" = {
          description = "Redis engine CPU on ${node} is above 75 percent."
          namespace   = "AWS/ElastiCache", metric = "EngineCPUUtilization", stat = "Average"
          dims        = tomap({ CacheClusterId = node }), op = "GreaterThanThreshold", threshold = 75
          period      = 300, evals = 3, datapoints = 3, missing = "notBreaching"
        }
        "redis-${node}-memory" = {
          description = "Redis memory usage on ${node} is above 80 percent."
          namespace   = "AWS/ElastiCache", metric = "DatabaseMemoryUsagePercentage", stat = "Average"
          dims        = tomap({ CacheClusterId = node }), op = "GreaterThanThreshold", threshold = 80
          period      = 300, evals = 3, datapoints = 3, missing = "notBreaching"
        }
      }
    ]...)
  )

  percentile_stats = ["p50", "p90", "p95", "p99"]
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  dimensions          = each.value.dims
  comparison_operator = each.value.op
  threshold           = each.value.threshold
  period              = each.value.period
  evaluation_periods  = each.value.evals
  datapoints_to_alarm = each.value.datapoints
  treat_missing_data  = each.value.missing

  statistic          = contains(local.percentile_stats, each.value.stat) ? null : each.value.stat
  extended_statistic = contains(local.percentile_stats, each.value.stat) ? each.value.stat : null

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# CloudFront 5xx error rate (us-east-1)
resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx" {
  provider = aws.us_east_1

  alarm_name          = "${local.name}-cloudfront-5xx-rate"
  alarm_description   = "More than 5 percent of CloudFront responses are 5xx."
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = aws_cloudfront_distribution.main.id
    Region         = "Global"
  }

  alarm_actions = [aws_sns_topic.edge_alerts.arn]
  ok_actions    = [aws_sns_topic.edge_alerts.arn]
}

# =============================================================================
# Event notifications
# =============================================================================
# RDS: failover, failure, storage, maintenance and recovery events.
resource "aws_db_event_subscription" "main" {
  name      = "${local.name}-rds-events"
  sns_topic = aws_sns_topic.alerts.arn

  source_type = "db-instance"
  source_ids  = [aws_db_instance.primary.identifier, aws_db_instance.replica.identifier]

  event_categories = [
    "availability",
    "failover",
    "failure",
    "low storage",
    "maintenance",
    "notification",
    "recovery",
    "read replica",
  ]

  depends_on = [aws_sns_topic_policy.alerts]
}

# Auto Scaling: every launch and termination, successful or not.
resource "aws_cloudwatch_event_rule" "asg_activity" {
  name        = "${local.name}-asg-activity"
  description = "Instance launches and terminations in the storefront Auto Scaling group"

  event_pattern = jsonencode({
    source = ["aws.autoscaling"]
    detail-type = [
      "EC2 Instance Launch Successful",
      "EC2 Instance Launch Unsuccessful",
      "EC2 Instance Terminate Successful",
      "EC2 Instance Terminate Unsuccessful",
    ]
    detail = {
      AutoScalingGroupName = [aws_autoscaling_group.app.name]
    }
  })
}

resource "aws_cloudwatch_event_target" "asg_activity_sns" {
  rule      = aws_cloudwatch_event_rule.asg_activity.name
  target_id = "sns-alerts"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      event    = "$.detail-type"
      instance = "$.detail.EC2InstanceId"
      cause    = "$.detail.Cause"
      detail   = "$.detail.Description"
      time     = "$.time"
    }
    input_template = "\"<time> Auto Scaling: <event> (<instance>). <detail>. Cause: <cause>\""
  }
}

# =============================================================================
# Dashboard
# =============================================================================
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 2
        properties = {
          markdown = "## ${local.name} storefront\nEdge, load balancer, web tier, database and cache health in one view. Alarms notify ${var.alert_email}."
        }
      },
      {
        type = "metric", x = 0, y = 2, width = 8, height = 6
        properties = {
          title = "ALB requests and errors", region = local.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 2, width = 8, height = 6
        properties = {
          title = "Target response time (p50, p95)", region = local.region, period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "p95" }],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 2, width = 8, height = 6
        properties = {
          title = "Healthy and unhealthy targets", region = local.region, stat = "Minimum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.app.arn_suffix, "LoadBalancer", aws_lb.main.arn_suffix],
            [".", "UnHealthyHostCount", ".", ".", ".", ".", { stat = "Maximum" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 8, height = 6
        properties = {
          title = "Auto Scaling capacity", region = local.region, stat = "Average", period = 60
          metrics = [
            ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", aws_autoscaling_group.app.name],
            [".", "GroupInServiceInstances", ".", "."],
            [".", "GroupPendingInstances", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 8, width = 8, height = 6
        properties = {
          title = "Web tier CPU", region = local.region, stat = "Average", period = 60
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.app.name],
          ]
          annotations = { horizontal = [{ label = "Scaling target", value = var.cpu_target_percent }] }
        }
      },
      {
        type = "metric", x = 16, y = 8, width = 8, height = 6
        properties = {
          title = "CloudFront requests and 5xx rate", region = "us-east-1", period = 300
          metrics = [
            ["AWS/CloudFront", "Requests", "DistributionId", aws_cloudfront_distribution.main.id, "Region", "Global", { stat = "Sum" }],
            [".", "5xxErrorRate", ".", ".", ".", ".", { stat = "Average", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 14, width = 8, height = 6
        properties = {
          title = "RDS CPU (primary and replica)", region = local.region, stat = "Average", period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.primary.identifier],
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.replica.identifier],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 14, width = 8, height = 6
        properties = {
          title = "RDS connections and replica lag", region = local.region, period = 60
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.primary.identifier, { stat = "Maximum" }],
            [".", "ReplicaLag", ".", aws_db_instance.replica.identifier, { stat = "Maximum", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 14, width = 8, height = 6
        properties = {
          title = "Redis cache hits and misses", region = local.region, stat = "Sum", period = 60
          metrics = concat(
            [for node in local.redis_nodes : ["AWS/ElastiCache", "CacheHits", "CacheClusterId", node]],
            [for node in local.redis_nodes : ["AWS/ElastiCache", "CacheMisses", "CacheClusterId", node]],
          )
        }
      },
    ]
  })
}
