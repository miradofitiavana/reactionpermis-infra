# IAM user dédié aux tests locaux du provider S3 Laravel par le dev.
#
# Pourquoi un user statique plutôt que le task role ECS ?
#   - Les rôles IAM ne peuvent pas être assumés depuis l'extérieur d'AWS avec
#     des access keys. Il faut SOIT un user + clés, SOIT IAM Identity Center
#     / SSO + STS assume-role. Pour un dev sur sa machine, user + clés c'est
#     le plus pragmatique.
#
# Sécurité :
#   - Scope strict R/W sur uniquement notre bucket uploads
#   - Pas de droits IAM, pas d'autres services, pas de droits admin
#   - Les clés sont dans le state TF (chiffré côté backend S3)
#   - À recycler avec `aws iam create-access-key` puis update du state si compromise
#
# Dev uniquement : en prod ce serait un credential long terme, dont le secret vit
# dans le state, pour un confort de poste de dev. Si le besoin se présente un jour
# de tester les uploads en local contre le bucket prod, lever le gate ponctuellement.

resource "aws_iam_user" "uploads_dev" {
  count = local.is_prod ? 0 : 1
  name  = "${local.name_prefix}-app-uploads-local-dev"

  tags = {
    Purpose = "Laravel S3 uploads local dev test"
  }
}

resource "aws_iam_access_key" "uploads_dev" {
  count = local.is_prod ? 0 : 1
  user  = aws_iam_user.uploads_dev[0].name
}

resource "aws_iam_user_policy" "uploads_dev" {
  count = local.is_prod ? 0 : 1
  name  = "uploads-rw"
  user  = aws_iam_user.uploads_dev[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AppBucketRW"
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:PutObjectAcl",
        "s3:GetObjectAcl",
      ]
      Resource = [
        aws_s3_bucket.uploads.arn,
        "${aws_s3_bucket.uploads.arn}/*",
      ]
    }]
  })
}
