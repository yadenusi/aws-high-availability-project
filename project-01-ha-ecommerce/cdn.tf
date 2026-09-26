# -----------------------------------------------------------------------------
# CloudFront
#   default        -> ALB, no caching (cart, orders, page render)
#   /api/products  -> ALB, cached 30 seconds at the edge (catalog reads)
#   /static/*      -> S3 through Origin Access Control, cached long term
# -----------------------------------------------------------------------------
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_cache_policy" "catalog" {
  name        = "${local.name}-catalog-30s"
  comment     = "Short edge cache for product catalog reads"
  min_ttl     = 0
  default_ttl = 30
  max_ttl     = 60

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "assets" {
  name                              = "${local.name}-assets"
  description                       = "CloudFront access to the private assets bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

locals {
  alb_origin_id    = "alb"
  assets_origin_id = "assets-s3"
}

resource "aws_cloudfront_distribution" "main" {
  #checkov:skip=CKV_AWS_305:The root path is served dynamically by the application, not by an object
  #checkov:skip=CKV_AWS_374:The storefront sells globally; no geo restriction is required

  enabled         = true
  is_ipv6_enabled = true
  comment         = "${local.name} storefront"
  price_class     = var.cloudfront_price_class
  http_version    = "http2and3"

  origin {
    origin_id   = local.alb_origin_id
    domain_name = local.origin_https ? var.origin_domain_name : aws_lb.main.dns_name

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = local.origin_https ? "https-only" : "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  origin {
    origin_id                = local.assets_origin_id
    domain_name              = aws_s3_bucket.this["assets"].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.assets.id
  }

  default_cache_behavior {
    target_origin_id           = local.alb_origin_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  ordered_cache_behavior {
    path_pattern               = "/api/products"
    target_origin_id           = local.alb_origin_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.catalog.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  ordered_cache_behavior {
    path_pattern               = "/static/*"
    target_origin_id           = local.assets_origin_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  # Serve a friendly maintenance page (from S3) if the whole origin is down.
  dynamic "custom_error_response" {
    for_each = [502, 503, 504]
    content {
      error_code            = custom_error_response.value
      response_code         = 503
      response_page_path    = "/static/maintenance.html"
      error_caching_min_ttl = 5
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
