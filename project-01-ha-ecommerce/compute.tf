# -----------------------------------------------------------------------------
# Web tier: launch template + Auto Scaling group in the private app subnets
# -----------------------------------------------------------------------------
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Log groups the CloudWatch agent on each instance ships to.
resource "aws_cloudwatch_log_group" "app" {
  for_each = toset(["nginx-access", "nginx-error", "storefront", "user-data"])

  name              = "/${local.name}/web/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

locals {
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region           = local.region
    name             = local.name
    artifact_bucket  = aws_s3_bucket.this["artifacts"].id
    app_key          = aws_s3_object.app_bundle.key
    app_md5          = data.archive_file.app.output_md5
    db_writer_host   = aws_db_instance.primary.address
    db_reader_host   = aws_db_instance.replica.address
    db_name          = aws_db_instance.primary.db_name
    db_secret_arn    = aws_db_instance.primary.master_user_secret[0].secret_arn
    redis_host       = aws_elasticache_replication_group.main.primary_endpoint_address
    redis_secret_arn = aws_secretsmanager_secret.redis_auth.arn
    log_group_prefix = "/${local.name}/web"
    cloudwatch_ns    = "${local.name}/web"
  })
}

resource "aws_launch_template" "app" {
  name_prefix   = "${local.name}-app-"
  description   = "Storefront web tier (AL2023, nginx, gunicorn, Flask)"
  image_id      = data.aws_ssm_parameter.al2023_ami.insecure_value
  instance_type = var.instance_type
  user_data     = base64encode(local.user_data)

  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # 1 minute metrics so scaling reacts quickly to load.
  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${local.name}-app", Tier = "app" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${local.name}-app-root" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  name                = "${local.name}-app-asg"
  vpc_zone_identifier = [for s in aws_subnet.app : s.id]
  target_group_arns   = [aws_lb_target_group.app.arn]

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  # Replace instances the ALB reports as unhealthy, not only failed EC2 checks.
  health_check_type         = "ELB"
  health_check_grace_period = 300
  default_instance_warmup   = 180
  wait_for_capacity_timeout = "15m"

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # Any launch template change (new AMI or new app bundle) rolls through the
  # group while keeping at least half the capacity in service.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 180
    }
  }

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = "${local.name}-app" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }

  # Instances boot against the database and cache, so those must exist first.
  depends_on = [
    aws_db_instance.replica,
    aws_elasticache_replication_group.main,
    aws_route.app_nat,
    aws_cloudwatch_log_group.app,
  ]

  lifecycle {
    # Scheduled and dynamic scaling change desired capacity at runtime.
    ignore_changes = [desired_capacity]
  }
}

# -----------------------------------------------------------------------------
# Scaling policies
# -----------------------------------------------------------------------------
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${local.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target_percent
  }
}

resource "aws_autoscaling_policy" "requests" {
  name                   = "${local.name}-requests-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
    target_value = var.requests_per_target
  }
}

# Optional: pre-scale ahead of a known daily peak (for example an evening sale).
resource "aws_autoscaling_schedule" "peak_up" {
  count = var.enable_peak_schedule ? 1 : 0

  scheduled_action_name  = "${local.name}-peak-up"
  autoscaling_group_name = aws_autoscaling_group.app.name
  recurrence             = var.peak_schedule.scale_up_cron
  min_size               = var.peak_schedule.peak_min_size
  max_size               = var.asg_max_size
  desired_capacity       = var.peak_schedule.peak_desired
  time_zone              = "Etc/UTC"
}

resource "aws_autoscaling_schedule" "peak_down" {
  count = var.enable_peak_schedule ? 1 : 0

  scheduled_action_name  = "${local.name}-peak-down"
  autoscaling_group_name = aws_autoscaling_group.app.name
  recurrence             = var.peak_schedule.scale_down_cron
  min_size               = var.asg_min_size
  max_size               = var.asg_max_size
  desired_capacity       = var.asg_desired_capacity
  time_zone              = "Etc/UTC"
}
