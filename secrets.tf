# Secrets Manager — valeurs sensibles injectées dans la task ECS.
#
# Secrets stockés :
#   - APP_KEY        : clé symétrique Laravel (cookies, sessions, encrypted casts)
#   - DB_PASSWORD    : mot de passe MySQL Laravel
#
# Pas de rotation auto pour l'instant. Si tu modifies une valeur, fais un
# `aws ecs update-service --force-new-deployment` pour que les tasks la repick.

# APP_KEY = base64:<32 bytes random>. Format attendu par Laravel.
resource "random_password" "app_key" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  name = "${local.name_prefix}-app"

  # Dev : suppression immédiate au destroy (pour recycler le nom).
  # Prod : 7 jours de corbeille (protection contre l'erreur humaine).
  recovery_window_in_days = local.is_prod ? 7 : 0
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    APP_KEY     = "base64:${base64encode(random_password.app_key.result)}"
    DB_PASSWORD = var.rds_password
  })
}
