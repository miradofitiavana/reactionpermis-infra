# Security Groups.
#
# On NE crée PAS de SG pour l'ALB (déjà existant, partagé aaaep).
# On crée :
#   - SG des tasks ECS app    : ingress 8080 depuis ALB partagé
#   - SG du filesystem EFS    : ingress 2049 (NFS) depuis SG app
#   - Ingress sur SG Aurora   : autorise SG app à parler en 3306
#
# Chemin réseau :
#   Internet → ALB partagé (443) → SG ECS app (8080) → SG Aurora (3306)
#                                       ↓
#                                  SG EFS (2049)

# ─── SG des tasks ECS Laravel ─────────────────────────────────────────────────

resource "aws_security_group" "ecs_app" {
  name        = "${local.name_prefix}-app-sg"
  description = "Laravel Fargate task SG"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Shared ALB to Laravel task"
    from_port       = var.app_container_port
    to_port         = var.app_container_port
    protocol        = "tcp"
    security_groups = [var.shared_alb_security_group_id]
  }

  egress {
    description = "All egress (Aurora, S3, ECR, Secrets Manager, CloudWatch, EFS)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─── SG du filesystem EFS ─────────────────────────────────────────────────────

resource "aws_security_group" "efs" {
  name        = "${local.name_prefix}-app-efs-sg"
  description = "EFS mount targets SG (NFS from ECS tasks)"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from Laravel tasks"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_app.id]
  }

  egress {
    description = "All egress (EFS metadata responses)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─── Règle d'ingress AJOUTÉE au SG Aurora existant ────────────────────────────
# `terraform destroy` retire proprement cette règle sans toucher au reste du SG.
resource "aws_security_group_rule" "rds_ingress_from_app" {
  description              = "Laravel task to Aurora MySQL"
  type                     = "ingress"
  from_port                = var.rds_port
  to_port                  = var.rds_port
  protocol                 = "tcp"
  security_group_id        = var.rds_security_group_id
  source_security_group_id = aws_security_group.ecs_app.id
}
