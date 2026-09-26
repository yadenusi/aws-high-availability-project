# -----------------------------------------------------------------------------
# Application Load Balancer across the public subnets of every AZ.
# It only forwards requests that carry the secret X-Origin-Verify header that
# CloudFront adds, so users cannot bypass the CDN by hitting the ALB directly.
# -----------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  enable_cross_zone_load_balancing = true
  drop_invalid_header_fields       = true
  enable_deletion_protection       = var.alb_deletion_protection
  idle_timeout                     = 60

  access_logs {
    bucket  = aws_s3_bucket.this["logs"].id
    prefix  = "alb"
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.this]
}

resource "aws_lb_target_group" "app" {
  name                 = "${local.name}-app-tg"
  port                 = local.app_port
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  stickiness {
    type    = "lb_cookie"
    enabled = false
  }
}

# ------------------------------ Listeners ------------------------------------
# Without a domain: a single HTTP listener, reachable only from CloudFront's
# origin-facing ranges (security group) and only with the secret header.
# With a domain and certificate: HTTPS does the forwarding and HTTP redirects.

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.origin_https ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.origin_https ? [] : [1]
    content {
      type = "fixed-response"
      fixed_response {
        content_type = "text/plain"
        message_body = "Direct access is not allowed."
        status_code  = "403"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.origin_https ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.alb_certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Direct access is not allowed."
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "forward_from_cloudfront" {
  listener_arn = local.origin_https ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }
}
