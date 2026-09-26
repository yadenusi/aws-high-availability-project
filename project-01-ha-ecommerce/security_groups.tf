# -----------------------------------------------------------------------------
# Security groups form a chain:
#   CloudFront -> ALB -> app instances -> RDS / ElastiCache
# Egress is written inline (so the AWS default allow-all egress is removed) and
# ingress uses standalone rule resources so SGs can reference each other
# without dependency cycles.
# -----------------------------------------------------------------------------

# CloudFront's origin-facing IP ranges, maintained by AWS.
data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# ---------------------------------- ALB --------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "ALB: accepts traffic from CloudFront only, forwards to the app tier"
  vpc_id      = aws_vpc.main.id

  egress {
    description     = "Forward to app instances"
    from_port       = local.app_port
    to_port         = local.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  tags = { Name = "${local.name}-alb-sg" }
}

# A single rule on purpose: the CloudFront prefix list has a large weight
# against the rules-per-SG quota, so only the listener port actually in use is opened.
resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "CloudFront origin-facing ranges"
  ip_protocol       = "tcp"
  from_port         = local.origin_port
  to_port           = local.origin_port
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin.id
}

# ---------------------------------- App --------------------------------------
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Web tier: HTTP from the ALB only; outbound HTTPS, MySQL and Redis"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "HTTPS to AWS APIs, package repos and the RDS CA bundle (via NAT or the S3 endpoint)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "MySQL to RDS"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.db.id]
  }

  egress {
    description     = "Redis to ElastiCache"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.cache.id]
  }

  tags = { Name = "${local.name}-app-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  #checkov:skip=CKV_AWS_260:Source is the ALB security group, not 0.0.0.0/0
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = local.app_port
  to_port                      = local.app_port
  referenced_security_group_id = aws_security_group.alb.id
}

# ---------------------------------- RDS --------------------------------------
resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "RDS MySQL: port 3306 from the app tier only, no outbound"
  vpc_id      = aws_vpc.main.id

  egress = []

  tags = { Name = "${local.name}-db-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from app instances"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.app.id
}

# ------------------------------- ElastiCache ---------------------------------
resource "aws_security_group" "cache" {
  name        = "${local.name}-cache"
  description = "ElastiCache Redis: port 6379 from the app tier only, no outbound"
  vpc_id      = aws_vpc.main.id

  egress = []

  tags = { Name = "${local.name}-cache-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_app" {
  security_group_id            = aws_security_group.cache.id
  description                  = "Redis from app instances"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.app.id
}
