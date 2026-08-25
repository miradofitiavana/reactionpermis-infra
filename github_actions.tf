# GitHub Actions OIDC — le repo Laravel déploie sans credentials AWS statiques.
#
# Pattern :
#   1. GitHub Actions génère un JWT signé pour chaque run
#   2. AWS vérifie via OIDC provider (token.actions.githubusercontent.com)
#   3. Si la trust policy match (repo + branche), STS délivre des credentials
#      temporaires (1h max) au workflow
#   4. Workflow push ECR + update ECS service avec ces credentials
#
# Avantages vs PAT/access key :
#   - Aucun secret à stocker dans GitHub Settings
#   - Credentials éphémères, scope strict au repo + ref

# OIDC provider GitHub : unique au compte AWS, créé en dehors de ce TF.
# Référence par data source pour ne pas le recréer (EntityAlreadyExists).
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# Rôle assumé par les workflows du repo reactionpermis-2026.
#
# Le sub OIDC porte la branche du run : restreindre dessus, c'est décider quelles
# branches ont le droit de déployer sur CET environnement. En prod on n'autorise
# que les branches qui déclenchent réellement un déploiement (cf. deploy.yml), pour
# qu'un workflow lancé depuis une branche de travail ne puisse pas obtenir des
# credentials sur le compte de production.
resource "aws_iam_role" "github_actions_app" {
  name = "${local.name_prefix}-github-actions-app"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            for b in var.github_deploy_branch_patterns :
            "repo:AAAEP/reactionpermis-2026:ref:refs/heads/${b}"
          ]
        }
      }
    }]
  })
}

# Policy inline : strict minimum pour push ECR + force-new-deployment ECS.
resource "aws_iam_role_policy" "github_actions_app" {
  name = "${local.name_prefix}-github-actions-app-deploy"
  role = aws_iam_role.github_actions_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*" # cette action n'accepte pas de scope
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
        ]
        Resource = aws_ecr_repository.app.arn
      },
      {
        Sid    = "ECSDeploy"
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "ecs:cluster" = aws_ecs_cluster.main.arn
          }
        }
      },
      {
        # Le workflow vérifie après déploiement qu'au moins une cible est saine
        # derrière l'ALB : « service stable » côté ECS ne dit rien de l'état du
        # health check. Lecture seule.
        Sid      = "ALBHealthRead"
        Effect   = "Allow"
        Action   = "elasticloadbalancing:DescribeTargetHealth"
        Resource = "*" # les actions Describe* d'ELBv2 n'acceptent pas de scope par ressource
      },
      {
        Sid    = "PassRole"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.task_execution.arn,
          aws_iam_role.task.arn,
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },
    ]
  })
}
