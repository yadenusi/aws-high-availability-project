# -----------------------------------------------------------------------------
# VPC: three subnet tiers in every AZ
#   public  : ALB and NAT gateways
#   app     : EC2 web tier (no public IPs)
#   data    : RDS and ElastiCache (no route to the internet at all)
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

# Remove every rule from the default security group so nothing can use it by accident.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-default-sg-locked" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-public-${each.key}"
    Tier = "public"
  }
}

resource "aws_subnet" "app" {
  for_each = local.app_subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = {
    Name = "${local.name}-app-${each.key}"
    Tier = "app"
  }
}

resource "aws_subnet" "data" {
  for_each = local.data_subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = {
    Name = "${local.name}-data-${each.key}"
    Tier = "data"
  }
}

# -----------------------------------------------------------------------------
# NAT gateways (one per AZ unless single_nat_gateway = true)
# -----------------------------------------------------------------------------
resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"

  tags = { Name = "${local.name}-nat-eip-${each.key}" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = { Name = "${local.name}-nat-${each.key}" }

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# Route tables
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-rt-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# One app route table per AZ so each AZ egresses through its own NAT.
resource "aws_route_table" "app" {
  for_each = toset(local.azs)

  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-rt-app-${each.key}" }
}

resource "aws_route" "app_nat" {
  for_each = toset(local.azs)

  route_table_id         = aws_route_table.app[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[var.single_nat_gateway ? local.azs[0] : each.key].id
}

resource "aws_route_table_association" "app" {
  for_each = aws_subnet.app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.app[each.key].id
}

# Data tier: local routes only. Databases never reach the internet.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-rt-data" }
}

resource "aws_route_table_association" "data" {
  for_each = aws_subnet.data

  subnet_id      = each.value.id
  route_table_id = aws_route_table.data.id
}

# -----------------------------------------------------------------------------
# S3 gateway endpoint: app downloads and S3 calls stay on the AWS network and
# skip NAT data processing charges.
# -----------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.app : rt.id]

  tags = { Name = "${local.name}-vpce-s3" }
}

# -----------------------------------------------------------------------------
# VPC flow logs to CloudWatch Logs (encrypted with the stack KMS key)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/${local.name}/vpc-flow-logs"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = [
      aws_cloudwatch_log_group.flow_logs.arn,
      "${aws_cloudwatch_log_group.flow_logs.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "vpc" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60

  tags = { Name = "${local.name}-flow-log" }
}
