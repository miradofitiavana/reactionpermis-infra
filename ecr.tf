# ECR (Elastic Container Registry) — registre Docker managé.
# On y push l'image Laravel construite localement / via GitHub Actions,
# et ECS Fargate la pull au démarrage des tasks.

resource "aws_ecr_repository" "app" {
  name = "${local.name_prefix}-app"

  # MUTABLE = on peut écraser un tag (ex: 'latest' poussé à chaque deploy dev).
  # En prod, le workflow pousse des tags immuables (prod-YYYYMMDD-sha7) pour rollback.
  image_tag_mutability = "MUTABLE"

  # Dev : autorise `terraform destroy` même si le repo contient des images.
  force_delete = !local.is_prod

  image_scanning_configuration {
    scan_on_push = true # Scan CVE automatique au push (gratuit).
  }
}

# Lifecycle policy : on garde les N dernières images, le reste est purgé.
# Évite que ECR grossisse indéfiniment (facturé au GB après le free tier).
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
