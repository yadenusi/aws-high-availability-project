output "storefront_url" {
  description = "Public entry point. Always use this URL, never the ALB directly."
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (for cache invalidations and metrics)."
  value       = aws_cloudfront_distribution.main.id
}

output "alb_dns_name" {
  description = "ALB DNS name. Direct requests should return 403, which proves the origin is locked to CloudFront."
  value       = aws_lb.main.dns_name
}

output "aws_region" {
  description = "Region the stack is deployed in."
  value       = local.region
}

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.main.id
}

output "availability_zones" {
  description = "AZs the stack is spread across."
  value       = local.azs
}

output "subnet_ids" {
  description = "Subnet IDs by tier and AZ."
  value = {
    public = { for az, s in aws_subnet.public : az => s.id }
    app    = { for az, s in aws_subnet.app : az => s.id }
    data   = { for az, s in aws_subnet.data : az => s.id }
  }
}

output "asg_name" {
  description = "Auto Scaling group name."
  value       = aws_autoscaling_group.app.name
}

output "target_group_arn" {
  description = "Target group ARN (for health checks in scripts)."
  value       = aws_lb_target_group.app.arn
}

output "db_writer_endpoint" {
  description = "RDS primary endpoint (writes). The DNS name follows the primary through a failover."
  value       = aws_db_instance.primary.address
}

output "db_reader_endpoint" {
  description = "RDS read replica endpoint (catalog reads)."
  value       = aws_db_instance.replica.address
}

output "db_instance_ids" {
  description = "RDS instance identifiers."
  value = {
    primary = aws_db_instance.primary.identifier
    replica = aws_db_instance.replica.identifier
  }
}

output "db_master_secret_arn" {
  description = "Secrets Manager ARN of the RDS managed master credentials."
  value       = aws_db_instance.primary.master_user_secret[0].secret_arn
}

output "redis_replication_group_id" {
  description = "ElastiCache replication group ID (used by the Redis failover script)."
  value       = aws_elasticache_replication_group.main.replication_group_id
}

output "redis_primary_endpoint" {
  description = "Redis primary endpoint."
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "alerts_topic_arns" {
  description = "SNS topics. Confirm the subscription email for each one."
  value = {
    main = aws_sns_topic.alerts.arn
    edge = aws_sns_topic.edge_alerts.arn
  }
}

output "dashboard_url" {
  description = "CloudWatch dashboard."
  value       = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "fis_experiment_template_ids" {
  description = "FIS experiment templates for the chaos tests."
  value = var.enable_fis ? {
    az_web_tier_loss   = aws_fis_experiment_template.az_web_tier_loss[0].id
    rds_force_failover = aws_fis_experiment_template.rds_force_failover[0].id
  } : {}
}

output "session_manager_hint" {
  description = "How to open a shell on a web instance without SSH."
  value       = "aws ssm start-session --region ${local.region} --target <instance-id>   (list IDs with: aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${aws_autoscaling_group.app.name} --query 'AutoScalingGroups[0].Instances[].InstanceId')"
}
