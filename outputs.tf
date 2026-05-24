# Outputs - valeurs utiles après apply.

output "shared_alb_dns_name" {
  value       = data.aws_lb.shared.dns_name
  description = "DNS brut de l'ALB partagé (target pour le CNAME app_fqdn dans Route53 prod)."
}

# ─── App / ECS ────────────────────────────────────────────────────────────────

output "app_ecr_repository_url" {
  value       = aws_ecr_repository.app.repository_url
  description = "Repo ECR où pousser l'image Laravel."
}

output "app_ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "app_ecs_service" {
  value = aws_ecs_service.app.name
}

output "app_target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "app_log_group" {
  value       = aws_cloudwatch_log_group.app.name
  description = "CloudWatch log group des tasks app. À tail via `aws logs tail`."
}

# ─── S3 + CloudFront uploads ──────────────────────────────────────────────────

output "uploads_s3_bucket" {
  value       = aws_s3_bucket.uploads.bucket
  description = "Bucket S3 où Laravel push les uploads via le disk 's3'."
}

output "uploads_cdn_url" {
  value       = "https://${aws_cloudfront_distribution.uploads.domain_name}"
  description = "URL CloudFront pour servir les uploads. À mettre en AWS_URL côté Laravel."
}

output "uploads_cdn_distribution_id" {
  value       = aws_cloudfront_distribution.uploads.id
  description = "ID de la distribution CloudFront (utile pour invalidation manuelle)."
}

# ─── EFS ──────────────────────────────────────────────────────────────────────

output "efs_file_system_id" {
  value = aws_efs_file_system.main.id
}

output "efs_access_point_cache_id" {
  value = aws_efs_access_point.cache.id
}

output "efs_access_point_sessions_id" {
  value = aws_efs_access_point.sessions.id
}

# ─── Secrets ──────────────────────────────────────────────────────────────────

output "app_secrets_arn" {
  value       = aws_secretsmanager_secret.app.arn
  description = "ARN du secret Laravel (APP_KEY, DB_PASSWORD). Référencé dans la task def."
}

# ─── FQDN ─────────────────────────────────────────────────────────────────────

output "app_acm_validation_records" {
  value = local.enable_app_fqdn ? {
    for dvo in aws_acm_certificate.app[0].domain_validation_options :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  } : {}
  description = "CNAME de validation ACM à créer dans Route53 prod (zone reactionpermis.fr)."
}

output "app_fqdn_cname_target" {
  value       = local.enable_app_fqdn ? data.aws_lb.shared.dns_name : null
  description = "Target pour le CNAME app_fqdn → ALB (à créer dans Route53 prod)."
}

output "app_url" {
  value       = local.enable_app_fqdn ? "https://${var.app_fqdn}" : "http://${data.aws_lb.shared.dns_name}"
  description = "URL finale de l'app (dispo après validation cert + CNAME)."
}

# ─── IAM dev user (clés statiques pour tests locaux S3) ───────────────────────

output "github_actions_app_role_arn" {
  value       = aws_iam_role.github_actions_app.arn
  description = "ARN à utiliser comme role-to-assume dans le workflow GitHub Actions Laravel."
}

output "uploads_dev_access_key_id" {
  value       = aws_iam_access_key.uploads_dev.id
  description = "AWS_ACCESS_KEY_ID pour tests locaux S3 (.env du projet 2026)."
}

output "uploads_dev_secret_access_key" {
  value       = aws_iam_access_key.uploads_dev.secret
  sensitive   = true
  description = "AWS_SECRET_ACCESS_KEY. Récupérer : `terraform output -raw uploads_dev_secret_access_key`"
}
