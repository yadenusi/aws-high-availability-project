data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:AZ names are resolved per account at plan time and stored in state; placement stays stable
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name       = "${var.project_name}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Three /24 tiers per AZ: public 0-9, app 10-19, data 20-29.
  public_subnets = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, i) }
  app_subnets    = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, i + 10) }
  data_subnets   = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, i + 20) }

  # One NAT per AZ for HA, or a single NAT in the first AZ for a cheaper lab.
  nat_azs = var.single_nat_gateway ? [local.azs[0]] : local.azs

  # HTTPS between CloudFront and the ALB only when a domain and certificate exist.
  origin_https = var.alb_certificate_arn != "" && var.origin_domain_name != ""
  origin_port  = local.origin_https ? 443 : 80

  app_port = 80

  # Static assets uploaded to S3 under static/ and served by CloudFront at /static/*.
  static_dir = "${path.module}/app/static"
  static_content_types = {
    css  = "text/css"
    js   = "application/javascript"
    svg  = "image/svg+xml"
    png  = "image/png"
    ico  = "image/x-icon"
    html = "text/html"
  }

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "Terraform"
    Capstone    = "SAA-C03 Project 1"
  }
}
