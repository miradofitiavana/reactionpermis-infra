# IAM pour ECS Fargate Laravel.
#
# 2 rôles séparés :
#   1. Task Execution Role : utilisé par l'agent ECS avant le démarrage du
#      conteneur (pull ECR, écriture logs CloudWatch, lecture secrets).
#   2. Task Role : utilisé PAR LE CONTENEUR au runtime. C'est ce rôle que
#      le SDK AWS embarqué dans Laravel récupère automatiquement (IMDS) pour
#      signer les appels S3 + EFS — pas de clé statique en prod.

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ─── 1. Task Execution Role ────────────────────────────────────────────────────

resource "aws_iam_role" "task_execution" {
  name               = "${local.name_prefix}-app-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# Policy managée AWS : ECR pull + CloudWatch Logs write.
resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Lecture du secret app (pour résoudre les `secrets:` de la task definition).
data "aws_iam_policy_document" "task_execution_extra" {
  statement {
    sid       = "ReadAppSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app.arn]
  }
}

resource "aws_iam_role_policy" "task_execution_extra" {
  name   = "app-secrets-read"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_extra.json
}

# ─── 2. Task Role (utilisé par Laravel) ────────────────────────────────────────

resource "aws_iam_role" "task" {
  name               = "${local.name_prefix}-app-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# Permissions S3 : lire/écrire dans NOTRE bucket uniquement.
data "aws_iam_policy_document" "task_s3" {
  statement {
    sid = "AppBucketRW"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:PutObjectAcl",
      "s3:GetObjectAcl",
    ]
    resources = [
      aws_s3_bucket.uploads.arn,
      "${aws_s3_bucket.uploads.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "task_s3" {
  name   = "app-s3"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_s3.json
}

# Permissions EFS : monter le filesystem + lire/écrire via les access points.
# La policy de NETWORK est dans le SG (port 2049 ouvert depuis SG ECS).
data "aws_iam_policy_document" "task_efs" {
  statement {
    sid = "MountEfs"
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
      "elasticfilesystem:ClientRootAccess",
    ]
    resources = [aws_efs_file_system.main.arn]

    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values = [
        aws_efs_access_point.cache.arn,
        aws_efs_access_point.sessions.arn,
      ]
    }
  }
}

resource "aws_iam_role_policy" "task_efs" {
  name   = "app-efs"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_efs.json
}
