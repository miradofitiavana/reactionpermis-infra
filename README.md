# reactionpermis-aws

Terraform pour le déploiement AWS du projet **reactionpermis-2026** (Laravel 12 monolithe).

## Architecture

```
                       Internet
                          │
                          ▼
            ┌─────────────────────────┐
            │ aaaep-site-web-alb      │ (ALB partagé, existant)
            │ listener 443 HTTPS      │
            └────────────┬────────────┘
                         │ Host: dev.reactionpermis.fr → forward
                         ▼
            ┌─────────────────────────┐
            │ Target Group ${name}-app│
            └────────────┬────────────┘
                         │ HTTP :8080
            ┌────────────▼────────────┐
            │ ECS Fargate task        │
            │  nginx + php-fpm 8.2    │
            │  Laravel 12 + Filament 4│
            └─┬──────┬──────┬─────────┘
              │      │      │
              ▼      ▼      ▼
        ┌────────┐ ┌────┐ ┌────────────────────┐
        │ Aurora │ │ S3 │ │ EFS                │
        │ MySQL  │ │bkt │ │ /cache + /sessions │
        │ (part.)│ │priv│ │ (file driver share)│
        └────────┘ └─┬──┘ └────────────────────┘
                    │ OAC
                    ▼
              ┌──────────────┐
              │ CloudFront   │
              └──────────────┘
```

| Composant | Détail |
|---|---|
| **Aurora MySQL** | `aaaep-db-mysql` (existant, partagé). Nouveau user `rp2026_<env>`. Tables Laravel préfixées `rp2026_` |
| **ALB** | `aaaep-site-web-alb` (existant, partagé). Listener rule host-based via FQDN |
| **ECS Fargate** | Cluster + service + task def Laravel. Image dans ECR managé |
| **S3 + CloudFront** | Bucket privé pour uploads Filament. CDN public via OAC |
| **EFS** | Filesystem partagé pour `storage/framework/cache` et `storage/framework/sessions` (driver Laravel `file` reste utilisable en multi-task) |
| **Secrets Manager** | APP_KEY + DB_PASSWORD. Pas de fichier .env en prod |
| **IAM** | Task role (S3 + EFS) + Task execution role + GitHub Actions OIDC role |

## Pourquoi EFS et pas Redis ?

Décision projet : on garde l'approche **"fichier HTML comme WordPress"** pour le ResponseCache + sessions (driver `file` Laravel, voir Spatie ResponseCache). Avec EFS, le même filesystem est partagé entre toutes les tasks ECS — un save dans Filament invalide partout, pas de Redis à provisionner.

Migration vers Redis ElastiCache possible plus tard : changer `SESSION_DRIVER`, `CACHE_STORE`, `RESPONSE_CACHE_DRIVER` en `redis` dans la task def + provisionner ElastiCache. Aucun code Laravel à toucher.

## Setup initial (one-time, hors Terraform)

### 1. Bucket de state (1 fois pour le compte)

Le lock est natif S3 depuis Terraform 1.10 (`use_lockfile = true` dans `backends/*.hcl`) → **pas besoin de DynamoDB**.

> PowerShell : quoter tout argument contenant un `=` (`"LocationConstraint=eu-west-3"`),
> sinon il est cassé sur le `=`.

```powershell
aws s3api create-bucket --bucket reactionpermis-tfstate --region eu-west-3 `
  --create-bucket-configuration "LocationConstraint=eu-west-3"

aws s3api put-bucket-versioning --bucket reactionpermis-tfstate `
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket reactionpermis-tfstate `
  --server-side-encryption-configuration '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}'

# Bloque tout accès public (le state contient secrets, ARNs, IDs).
aws s3api put-public-access-block --bucket reactionpermis-tfstate `
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### 2. User MySQL Laravel sur l'Aurora

**Pas de création** : on réutilise le user existant `aaaep_aaaeporganisme` (même que `reactionpermis-back`). Il a déjà tous les droits nécessaires sur la base `aaaep_aaaeporganisme.*`, y compris CREATE/ALTER/DROP TABLE pour les migrations `rp2026_*`.

Le password est le même que celui déjà présent dans le `.env` du back / du projet 2026 :

```powershell
$env:TF_VAR_rds_password = '<MÊME_VALEUR_QUE_TON_ENV_LOCAL>'
```

Plus tard, si tu veux scoper les droits par app (sécurité défense en profondeur), tu pourras créer un user dédié `rp2026_<env>` et changer `rds_username` dans le tfvars.

### 3. Init + plan + apply

```powershell
. .\.env.dev.ps1   # source TF_VAR_rds_password

terraform init -reconfigure "-backend-config=backends/dev.hcl"
terraform plan  "-var-file=envs/dev.tfvars"
terraform apply "-var-file=envs/dev.tfvars"
```

Les **guillemets** autour de `"-backend-config=..."` / `"-var-file=..."` sont obligatoires sous PowerShell : sans eux, il casse l'argument sur le `=` (Terraform voit alors un argument positionnel → « Too many command line arguments »). Le token `--%` (stop-parsing) avant le flag marche aussi.

Le premier apply crée tout sauf le cert ACM validé : le service ECS va crash-looper tant qu'aucune image n'est dans ECR. C'est attendu.

### 4. Cert ACM — validation manuelle dans Route53 prod

L'apply crée le cert en `PENDING_VALIDATION`. Récupère les records :

```powershell
terraform output app_acm_validation_records
```

Dans la **console Route53 du compte prod** (la zone `reactionpermis.fr`), créer ces CNAME (1 par domaine). Attendre ~5-15 min, vérifier le passage en `ISSUED` :

```powershell
aws acm list-certificates --region eu-west-3
aws acm describe-certificate --certificate-arn <arn> --region eu-west-3 `
  --query 'Certificate.Status'
```

### 5. CNAME du FQDN → ALB

```powershell
terraform output app_fqdn_cname_target
```

Dans Route53 prod, créer le CNAME `dev.reactionpermis.fr → <ALB DNS>`.

### 6. Premier push image Laravel

Côté projet `reactionpermis-2026` :

```powershell
$env:AWS_ACCOUNT = aws sts get-caller-identity --query Account --output text
$env:REGION = "eu-west-3"
$env:ECR = terraform -chdir=D:\reaction-permis\reactionpermis-aws output -raw app_ecr_repository_url

aws ecr get-login-password --region $env:REGION | `
  docker login --username AWS --password-stdin "$env:AWS_ACCOUNT.dkr.ecr.$env:REGION.amazonaws.com"

docker build -t "$env:ECR`:latest" .
docker push "$env:ECR`:latest"

aws ecs update-service `
  --cluster $(terraform -chdir=D:\reaction-permis\reactionpermis-aws output -raw app_ecs_cluster) `
  --service $(terraform -chdir=D:\reaction-permis\reactionpermis-aws output -raw app_ecs_service) `
  --force-new-deployment --region eu-west-3
```

### 7. Migrations Laravel (tu les lances toi-même)

```bash
# Local, contre l'Aurora dev (depuis une IP whitelistée) :
php artisan migrate --force
```

Pas d'entrypoint container automatique : tu contrôles 100% des migrations.

## Layout

```
.
├── *.tf                # code commun
├── backend.tf          # backend S3 (activé)
├── backends/
│   ├── dev.hcl
│   └── prod.hcl
├── envs/
│   ├── dev.tfvars
│   └── prod.tfvars
└── README.md
```

## URLs après apply

```powershell
terraform output app_url       # https://dev.reactionpermis.fr
terraform output uploads_cdn_url   # https://dxxxxx.cloudfront.net
terraform output app_log_group     # /ecs/reactionpermis-dev-app
```

Tail des logs :
```powershell
aws logs tail $(terraform output -raw app_log_group) --follow --region eu-west-3
```

## CI/CD

Le workflow GitHub Actions du repo `reactionpermis-2026` assume le rôle OIDC :

```powershell
terraform output github_actions_app_role_arn
```

À mettre dans `AWS_ROLE_ARN` du workflow (`.github/workflows/deploy.yml` côté projet 2026).

## Dev local : push manuel S3 depuis sa machine

Le TF crée un IAM user dédié avec accès au bucket uniquement. Récupérer les clés :

```powershell
terraform output -raw uploads_dev_access_key_id
terraform output -raw uploads_dev_secret_access_key
terraform output -raw uploads_s3_bucket
```

À mettre dans le `.env` local de `reactionpermis-2026` :
```
AWS_ACCESS_KEY_ID=AKIAxxxxxxxx
AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxx
AWS_DEFAULT_REGION=eu-west-3
AWS_BUCKET=reactionpermis-dev-app-uploads-xxxxxxxx
AWS_URL=https://xxxxxxxx.cloudfront.net
UPLOADS_DISK=s3
```

## Prod

`envs/prod.tfvars` est un squelette. À finaliser quand on attaque la prod (VPC prod, ALB prod, cluster Aurora prod, etc.).
