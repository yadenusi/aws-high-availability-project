# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------
variable "project_name" {
  description = "Short lowercase project name used in every resource name."
  type        = string
  default     = "ecommerce-ha"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.project_name))
    error_message = "project_name must be 3 to 16 characters of lowercase letters, digits or hyphens (ALB and target group names are limited to 32 characters)."
  }
}

variable "environment" {
  description = "Environment name, appended to the project name."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be dev, test or prod."
  }
}

variable "owner" {
  description = "Person responsible for the resources, applied as a tag."
  type        = string
  default     = "Yusuf Adenusi"
}

variable "aws_region" {
  description = "Primary region for the stack."
  type        = string
  default     = "us-east-2"
}

variable "alert_email" {
  description = "Email address that receives alarm, failover and scaling notifications. Each SNS subscription must be confirmed from the inbox."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "log_retention_days" {
  description = "Retention for every CloudWatch log group created by this stack."
  type        = number
  default     = 30
}

variable "secret_recovery_window_days" {
  description = "Days Secrets Manager keeps a deleted secret. 0 deletes immediately so the lab can be destroyed and redeployed the same day; use 7 to 30 for anything long lived."
  type        = number
  default     = 0

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 or between 7 and 30."
  }
}

variable "force_destroy_buckets" {
  description = "Let terraform destroy empty and delete the S3 buckets. Lab setting; set false for anything long lived."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block of the VPC. Subnets are carved as /24s from it."
  type        = string
  default     = "10.10.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 18
    error_message = "vpc_cidr must be a valid CIDR of /18 or larger."
  }
}

variable "az_count" {
  description = "Number of Availability Zones to spread across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3. High availability needs at least 2."
  }
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway for all AZs to save cost. This reintroduces a single point of failure for outbound traffic, so keep it false for the HA tests."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Edge (CloudFront and ALB)
# -----------------------------------------------------------------------------
variable "cloudfront_price_class" {
  description = "CloudFront price class. PriceClass_100 covers North America and Europe."
  type        = string
  default     = "PriceClass_100"
}

variable "alb_certificate_arn" {
  description = "Optional ACM certificate ARN (in the stack region) for an HTTPS listener on the ALB. Requires origin_domain_name."
  type        = string
  default     = ""
}

variable "origin_domain_name" {
  description = "Optional DNS name that points at the ALB and matches alb_certificate_arn. When both are set, CloudFront talks to the ALB over HTTPS."
  type        = string
  default     = ""
}

variable "alb_deletion_protection" {
  description = "Enable ALB deletion protection. Off by default so the lab can be destroyed."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Compute
# -----------------------------------------------------------------------------
variable "instance_type" {
  description = "EC2 instance type for the web tier."
  type        = string
  default     = "t3.micro"
}

variable "asg_min_size" {
  description = "Minimum instances. Keep at least one per AZ."
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "Desired instances at launch."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum instances during scale out."
  type        = number
  default     = 6

  validation {
    condition     = var.asg_max_size >= 2
    error_message = "asg_max_size must be at least 2."
  }
}

variable "cpu_target_percent" {
  description = "Average CPU the target tracking policy holds the group at."
  type        = number
  default     = 50
}

variable "requests_per_target" {
  description = "ALB requests per target per minute that the request count policy holds the group at."
  type        = number
  default     = 1000
}

variable "enable_peak_schedule" {
  description = "Create scheduled actions that pre-scale the group for a daily peak window."
  type        = bool
  default     = false
}

variable "peak_schedule" {
  description = "Daily peak window in UTC cron form, with the capacity to hold during it."
  type = object({
    scale_up_cron   = string
    scale_down_cron = string
    peak_min_size   = number
    peak_desired    = number
  })
  default = {
    scale_up_cron   = "0 17 * * *"
    scale_down_cron = "0 23 * * *"
    peak_min_size   = 4
    peak_desired    = 4
  }
}

# -----------------------------------------------------------------------------
# Database
# -----------------------------------------------------------------------------
variable "db_engine_version" {
  description = "RDS MySQL major or full engine version."
  type        = string
  default     = "8.0"
}

variable "db_instance_class" {
  description = "Instance class for the primary and the read replica."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB."
  type        = number
  default     = 100
}

variable "db_backup_retention_days" {
  description = "Automated backup retention. Must be at least 1 for read replicas to work."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_days >= 1
    error_message = "Read replicas require automated backups, so retention must be at least 1 day."
  }
}

variable "db_performance_insights" {
  description = "Enable Performance Insights. Not supported on db.t3.micro or db.t3.small for MySQL."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Enable RDS deletion protection. Off by default so the lab can be destroyed."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Lab setting."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Cache
# -----------------------------------------------------------------------------
variable "redis_engine_version" {
  description = "ElastiCache Redis OSS engine version."
  type        = string
  default     = "7.1"
}

variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_num_cache_clusters" {
  description = "Nodes in the replication group (one primary, the rest replicas). At least 2 for automatic failover."
  type        = number
  default     = 2

  validation {
    condition     = var.redis_num_cache_clusters >= 2 && var.redis_num_cache_clusters <= 6
    error_message = "Automatic failover needs 2 to 6 nodes."
  }
}

# -----------------------------------------------------------------------------
# Chaos testing
# -----------------------------------------------------------------------------
variable "enable_fis" {
  description = "Create the AWS Fault Injection Service experiment templates."
  type        = bool
  default     = true
}
