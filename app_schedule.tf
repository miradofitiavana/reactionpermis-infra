# Auto start/stop ECS pour économiser quand on code pas.
#
# Pattern : 2 EventBridge schedules cron qui appellent ecs:UpdateService direct
# (target "AWS API" - pas de Lambda).
#
# Comportement par défaut quand activé :
#   - Lundi-Vendredi 7h Paris : desired_count = 1 (start)
#   - Lundi-Vendredi 22h Paris : desired_count = 0 (stop)
#   - Samedi-Dimanche : reste à 0 (pas de start le samedi)
#
# Coût ECS réduit d'environ 60% : ~75h tournant / 168h semaine = ~45% de la facture
# 24/7 → ~8 $/mois au lieu de ~18 $/mois.
#
# Override manuel possible à tout moment :
#   aws ecs update-service --cluster <c> --service <s> --desired-count 1 --region eu-west-3
# Le schedule suivant écrasera ta modif (donc 1h après pour un dimanche après-midi
# ça redescend à 0). À toi de désactiver le schedule temporairement si besoin
# d'override long.

locals {
  enable_schedule = var.app_schedule_enabled
}

# ─── IAM role assumé par EventBridge Scheduler pour appeler ECS ──────────────

resource "aws_iam_role" "scheduler" {
  count = local.enable_schedule ? 1 : 0
  name  = "${local.name_prefix}-app-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  count = local.enable_schedule ? 1 : 0
  name  = "${local.name_prefix}-app-scheduler-ecs"
  role  = aws_iam_role.scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "UpdateAppService"
      Effect = "Allow"
      Action = "ecs:UpdateService"
      # Scope strict : uniquement notre service ECS, pas tout le cluster.
      Resource = aws_ecs_service.app.id
    }]
  })
}

# ─── Schedule START : Lun-Ven matin → desired_count = 1 ──────────────────────

resource "aws_scheduler_schedule" "app_start" {
  count      = local.enable_schedule ? 1 : 0
  name       = "${local.name_prefix}-app-start"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.app_schedule_start_cron
  schedule_expression_timezone = var.app_schedule_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ecs:updateService"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      Cluster      = aws_ecs_cluster.main.name
      Service      = aws_ecs_service.app.name
      DesiredCount = 1
    })
  }
}

# ─── Schedule STOP : Lun-Ven soir → desired_count = 0 ────────────────────────

resource "aws_scheduler_schedule" "app_stop" {
  count      = local.enable_schedule ? 1 : 0
  name       = "${local.name_prefix}-app-stop"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.app_schedule_stop_cron
  schedule_expression_timezone = var.app_schedule_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ecs:updateService"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      Cluster      = aws_ecs_cluster.main.name
      Service      = aws_ecs_service.app.name
      DesiredCount = 0
    })
  }
}

output "app_schedule_status" {
  value = local.enable_schedule ? {
    enabled    = true
    timezone   = var.app_schedule_timezone
    start_cron = var.app_schedule_start_cron
    stop_cron  = var.app_schedule_stop_cron
  } : { enabled = false }
  description = "Récap du schedule auto start/stop ECS."
}
