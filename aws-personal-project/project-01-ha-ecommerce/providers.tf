provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# CloudFront publishes its metrics only in us-east-1, so the CloudFront alarm
# and the SNS topic it notifies must live there.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}
