# CloudFront devant le bucket S3 uploads.
#
# Pourquoi ?
#   - Bucket S3 reste privé (block public access) — seul CloudFront peut lire via OAC.
#   - Les utilisateurs voient des URLs `https://dxxxxx.cloudfront.net/<file>` (ou
#     domaine custom plus tard).
#   - Cache CDN edge → temps de réponse ~50ms partout en Europe.
#   - HTTPS géré par CloudFront (cert *.cloudfront.net gratuit par défaut).
#
# Coût : quasi nul (1 TB + 10M requêtes/mois offerts à vie par AWS).

# OAC (Origin Access Control) : la version moderne d'OAI. CloudFront signe ses
# requêtes S3 avec Sigv4, seul lui peut lire le bucket.
resource "aws_cloudfront_origin_access_control" "uploads" {
  name                              = "${local.name_prefix}-app-uploads-oac"
  description                       = "OAC for Laravel uploads bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "uploads" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${local.name_prefix} Laravel uploads CDN"

  # PriceClass_100 = US + Europe + Israel. Le moins cher.
  # Pour du trafic français, plus que suffisant.
  price_class = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.uploads.bucket_regional_domain_name
    origin_id                = "uploads-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.uploads.id
  }

  default_cache_behavior {
    target_origin_id       = "uploads-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Managed cache policy "CachingOptimized" : TTL long, pas de forward
    # cookies/query. Parfait pour images / assets immuables.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    # Managed origin request policy "CORS-S3Origin" : forward les headers
    # CORS pour que S3 réponde correctement aux requêtes cross-origin.
    origin_request_policy_id = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"
  }

  # Cert : on utilise le *.cloudfront.net par défaut. Pour un domaine custom
  # (ex: cdn.reactionpermis.fr) il faudrait un cert ACM en us-east-1
  # (contrainte CloudFront) + aliases = ["cdn.reactionpermis.fr"].
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Purpose = "Laravel uploads CDN"
  }
}

# Bucket policy : autorise CloudFront OAC à lire les objets.
# Principal scopé au service AWS (pas "*"), donc pas bloqué par PAB.
resource "aws_s3_bucket_policy" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOACRead"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.uploads.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.uploads.arn
        }
      }
    }]
  })
}
