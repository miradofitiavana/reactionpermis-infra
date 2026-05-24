# Bucket S3 pour TOUS les uploads Laravel.
#
# Utilisé par Filament (logos, images hero, covers articles, rich-editor attachments)
# via le disk Storage 's3'. Le bucket est privé, servi en lecture publique via
# CloudFront (OAC) — cf cloudfront.tf.
#
# Credentials côté tasks ECS : task role IAM, pas de clé statique.
# Côté dev local : user IAM dédié + access key (cf iam_dev_user.tf).

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "uploads" {
  bucket = "${local.name_prefix}-app-uploads-${random_id.bucket_suffix.hex}"
  # Dev : force_destroy autorise `terraform destroy` même si le bucket a du contenu.
  # Prod : bloque pour éviter une suppression accidentelle des médias éditeur.
  force_destroy = !local.is_prod
}

# 4 interrupteurs anti-fuite : empêche TOUT accès public anonyme accidentel.
resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# BucketOwnerEnforced : ACLs désactivées, le compte propriétaire possède tout.
# Recommandé AWS depuis avril 2023.
resource "aws_s3_bucket_ownership_controls" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Versioning : permet de récupérer un upload écrasé par erreur depuis Filament.
# Coût négligeable pour des uploads peu fréquents.
resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Chiffrement au repos par défaut (SSE-S3, gratuit).
resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CORS : nécessaire si le navigateur charge directement une image via URL
# présignée (rare) ou via CloudFront avec CORS forwardé. Lecture seule, all origins.
resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

# Cycle de vie : purge auto des anciennes versions après 30 jours pour limiter
# le coût de stockage du versioning sur images écrasées.
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
