# ECS Fargate — cluster + task definition + service Laravel.
#
# Concepts :
#   - Cluster    : conteneur logique de services (1 par env)
#   - Task def   : blueprint immuable d'un conteneur (image, ressources, env vars)
#   - Service   : garde N tasks vivantes à partir d'une task def, gère le rolling
#                  deploy quand on change la task def
#
# EFS : 2 volumes montés via access points, scope par dossier.
#       - /var/www/html/storage/framework/cache    ← ResponseCache + app cache
#       - /var/www/html/storage/framework/sessions ← sessions Laravel

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name_prefix}-app"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # payant ($), on garde simple en dev
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name_prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.app_cpu
  memory                   = var.app_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  # ─── Volumes EFS ──────────────────────────────────────────────────────────
  volume {
    name = "laravel-cache"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.main.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.cache.id
        iam             = "ENABLED"
      }
    }
  }

  volume {
    name = "laravel-sessions"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.main.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.sessions.id
        iam             = "ENABLED"
      }
    }
  }

  # ─── Container Laravel ────────────────────────────────────────────────────
  container_definitions = jsonencode([{
    name      = "app"
    image     = "${aws_ecr_repository.app.repository_url}:${var.app_image_tag}"
    essential = true

    portMappings = [{
      containerPort = var.app_container_port
      protocol      = "tcp"
    }]

    # Mount des access points EFS sur les bons dossiers Laravel.
    # PHP-FPM tourne en uid 33 (www-data) sur l'image, les access points
    # imposent posix_user 33:33 → permissions cohérentes.
    mountPoints = [
      {
        sourceVolume  = "laravel-cache"
        containerPath = "/var/www/html/storage/framework/cache"
        readOnly      = false
      },
      {
        sourceVolume  = "laravel-sessions"
        containerPath = "/var/www/html/storage/framework/sessions"
        readOnly      = false
      },
    ]

    environment = concat([
      # Laravel core
      { name = "APP_ENV", value = var.app_env },
      { name = "APP_DEBUG", value = tostring(var.app_debug) },
      { name = "APP_URL", value = var.app_fqdn != "" ? "https://${var.app_fqdn}" : "https://${data.aws_lb.shared.dns_name}" },
      { name = "LOG_CHANNEL", value = "stderr" }, # logs → stdout/stderr → CloudWatch

      # Drivers : file (sur EFS) pour rester en mode "fichier comme WordPress"
      { name = "SESSION_DRIVER", value = "file" },
      { name = "CACHE_STORE", value = "file" },
      { name = "QUEUE_CONNECTION", value = "sync" },
      # Store dédié au cache HTML (config/cache.php côté app) : avec `file`, le
      # `flush()` de responsecache vidait aussi le cache applicatif partagé.
      { name = "RESPONSE_CACHE_DRIVER", value = "responses" },

      # Database — Aurora MySQL partagé
      { name = "DB_CONNECTION", value = "mysql" },
      { name = "DB_HOST", value = var.rds_endpoint },
      { name = "DB_PORT", value = tostring(var.rds_port) },
      { name = "DB_DATABASE", value = var.rds_database_name },
      { name = "DB_USERNAME", value = var.rds_username },

      # Filesystem : Filament uploads → S3 + CloudFront
      { name = "UPLOADS_DISK", value = "s3" },
      { name = "AWS_BUCKET", value = aws_s3_bucket.uploads.bucket },
      { name = "AWS_DEFAULT_REGION", value = var.aws_region },
      { name = "AWS_URL", value = "https://${aws_cloudfront_distribution.uploads.domain_name}" },
      # Pas de AWS_ACCESS_KEY_ID/SECRET — le SDK utilise le task role IAM via IMDS.

      # Trust proxies : ALB termine TLS, X-Forwarded-* headers à respecter.
      { name = "TRUSTED_PROXIES", value = "*" },

      # Paiement Lyra / PayZen (tunnel de réservation).
      # LYRA_PK n'est pas un secret : le formulaire embarqué Krypton la charge dans
      # le navigateur. Seuls username et password passent par Secrets Manager.
      { name = "LYRA_PK", value = var.lyra_public_key },
      { name = "LYRA_ENDPOINT", value = var.lyra_endpoint },
      # Doit rester l'endpoint REACTION de l'API organisme : c'est lui qui pose
      # MP_SITE_LYRA_CONFIRMED_REACTION sur la réservation.
      { name = "LYRA_IPN_URL", value = var.lyra_ipn_url },

      ],
      # Sentry : PROD SEULEMENT, décision du 2026-08-26. Le dev n'a ni DSN ni
      # SENTRY_ENVIRONMENT, donc le SDK y reste inerte même si quelqu'un remplit
      # un envs/dev.secret.tfvars par erreur. SENTRY_RELEASE est déjà dans
      # l'image (Dockerfile). Traces de performance coupées (quota) :
      # surchargeable via app_extra_env pour observer une période.
      local.is_prod && var.sentry_dsn != "" ? [
        { name = "SENTRY_LARAVEL_DSN", value = var.sentry_dsn },
        { name = "SENTRY_ENVIRONMENT", value = var.environment },
        { name = "SENTRY_TRACES_SAMPLE_RATE", value = "0" },
      ] : [],
      # Permet d'ajouter / overrider des env vars sans modifier ce fichier.
      [for k, v in var.app_extra_env : { name = k, value = v }],
    )

    # Env vars sensibles : ECS les résout depuis Secrets Manager à la volée.
    # Le conteneur ne voit que la valeur finale (pas le JSON enveloppe).
    secrets = [
      { name = "APP_KEY", valueFrom = "${aws_secretsmanager_secret.app.arn}:APP_KEY::" },
      { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.app.arn}:DB_PASSWORD::" },
      # Identifiants boutique Lyra. La syntaxe `:CLE::` demande a ECS d'extraire une
      # seule clé du JSON du secret (les deux `:` finaux = version-stage et
      # version-id laissés vides, donc « version courante »).
      { name = "LYRA_USERNAME", valueFrom = "${aws_secretsmanager_secret.app.arn}:LYRA_USERNAME::" },
      { name = "LYRA_PWD", valueFrom = "${aws_secretsmanager_secret.app.arn}:LYRA_PWD::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "app"
      }
    }

    # Health check container-level (en plus du health check ALB).
    # Curl /up depuis l'intérieur — détecte un PHP-FPM mort avant que l'ALB le voit.
    healthCheck = {
      command     = ["CMD-SHELL", "curl -fsS http://localhost:${var.app_container_port}/up || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = "${local.name_prefix}-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.app_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = var.ecs_task_subnet_ids
    security_groups = [aws_security_group.ecs_app.id]
    # En VPC aaaep : subnets publics sans NAT → IP publique nécessaire pour
    # pull ECR + appels S3/Secrets via internet gateway. Le SG bloque tous
    # les inbound non autorisés, donc pas d'exposition réelle.
    assign_public_ip = var.assign_public_ip_to_tasks
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.app_container_port
  }

  # Rolling deploy zero-downtime : min 100% / max 200%.
  # ECS lance la NOUVELLE task d'abord (200% temporairement), attend qu'elle soit
  # healthy sur l'ALB, PUIS draine l'ancienne. Aucun moment où 0 task tourne.
  # Coût : pendant ~1 min on facture 2 tasks au lieu de 1 (négligeable en dev).
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Health check grace period : laisse le temps à Laravel + EFS mount + opcache
  # warmup avant que l'ALB commence à pinger /up.
  health_check_grace_period_seconds = 60

  # Le service ne peut pas s'enregistrer dans l'ALB tant que la listener rule
  # n'est pas là (host-based routing).
  depends_on = [
    aws_efs_mount_target.main,
  ]

  # Ignore desired_count si autoscaling y touche plus tard (pas encore configuré).
  lifecycle {
    ignore_changes = [
      desired_count,
    ]
  }
}
