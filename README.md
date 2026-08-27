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
| **Secrets Manager** | APP_KEY + DB_PASSWORD + LYRA_USERNAME + LYRA_PWD. Pas de fichier .env en prod |
| **IAM** | Task role (S3 + EFS) + Task execution role + GitHub Actions OIDC role |

## Pourquoi EFS et pas Redis ?

Décision projet : on garde l'approche **"fichier HTML comme WordPress"** pour le ResponseCache + sessions (driver `file` Laravel, voir Spatie ResponseCache). Avec EFS, le même filesystem est partagé entre toutes les tasks ECS — un save dans Filament invalide partout, pas de Redis à provisionner.

Migration vers Redis ElastiCache possible plus tard : changer `SESSION_DRIVER`, `CACHE_STORE`, `RESPONSE_CACHE_DRIVER` en `redis` dans la task def + provisionner ElastiCache. Aucun code Laravel à toucher.

## Setup initial (one-time, hors Terraform)

### 1. Bucket de state (1 fois pour le compte)

Le lock est natif S3 depuis Terraform 1.10 (`use_lockfile = true` dans `backends/*.hcl`) → **pas besoin de DynamoDB**.

> PowerShell : quoter tout argument contenant un `=` (`"LocationConstraint=eu-west-3"`),
> sinon il est cassé sur le `=`.

**Un bucket par compte** : `reactionpermis-tfstate` appartient au compte dev,
`reactionpermis-tfstate-prod` au compte prod. Le state d'un compte doit rester
dans le compte qu'il décrit — depuis la prod, un `head-bucket` sur le bucket dev
répond de toute façon 403.

```powershell
$B = "reactionpermis-tfstate"        # ou reactionpermis-tfstate-prod, selon le compte
aws s3api create-bucket --bucket $B --region eu-west-3 `
  --create-bucket-configuration "LocationConstraint=eu-west-3"

aws s3api put-bucket-versioning --bucket $B `
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket $B `
  --server-side-encryption-configuration '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}'

# Bloque tout accès public (le state contient secrets, ARNs, IDs).
aws s3api put-public-access-block --bucket $B `
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### 2. User MySQL Laravel sur l'Aurora

**Dev** : on réutilise le user existant `aaaep_aaaeporganisme`, qui a tous les
droits sur `aaaep_aaaeporganisme.*`, migrations `rp2026_*` comprises.

**Prod** : user dédié `rp2026'@'10.0.%'`, **sans aucun droit DDL**, créé par
`docs/2026-08-25-user-mysql-rp2026.sql`. C'est la convention du parc depuis
2026-08-05 (un user MySQL par application) : elle rend la consommation
attribuable sur un cluster partagé, plafonne les connexions par application, et
surtout supprime le rayon de souffle — MySQL n'acceptant pas de joker sur le nom
de table dans un GRANT, un user capable de créer ses tables aurait forcément pu
détruire le legacy. C'est possible parce que le conteneur ne joue jamais les
migrations (`docker/entrypoint.sh`) : elles sont lancées à la main par l'admin.

⚠️ Les deux clusters Aurora sont **distincts** : `aaaep-db-mysql` côté dev,
`aaaep-db-mysql-v1-cluster` côté prod. Les deux portent une base nommée
`aaaep_aaaeporganisme`, ce qui rend la confusion facile.

### 2 bis. Secrets : jamais dans Terraform

Terraform crée le **conteneur** du secret (`reactionpermis-<env>-app`) avec quatre
placeholders `A_INJECTER` et `ignore_changes = [secret_string]`. Les valeurs sont
poussées hors Terraform, parce que tout ce que Terraform manipule atterrit en
clair dans le tfstate — y compris le résultat d'un `data` source, et y compris une
variable marquée `sensitive`, qui n'est masquée qu'à l'affichage.

```powershell
$j = @{ APP_KEY='base64:...'; DB_PASSWORD='...'; LYRA_USERNAME='...'; LYRA_PWD='...' } | ConvertTo-Json -Compress
aws secretsmanager put-secret-value --secret-id reactionpermis-dev-app --secret-string $j
aws ecs update-service --cluster reactionpermis-dev-cluster --service reactionpermis-dev-app --force-new-deployment
```

`put-secret-value` remplace le JSON **entier** : pousser une seule clé efface les
autres et coupe l'accès MySQL. Toujours relire, modifier, repousser le tout. Les
quatre clés doivent exister, `ecs.tf` les référence une par une et ECS refuse de
démarrer la task si l'une manque.

### 2 ter. Boutique Lyra / PayZen (paiement du test psychotechnique)

| Variable | Où la mettre | Pourquoi |
|---|---|---|
| `LYRA_USERNAME` | Secrets Manager (`put-secret-value`) | credential API |
| `LYRA_PWD` | Secrets Manager (`put-secret-value`) | credential API |
| `lyra_public_key` | `envs/<env>.tfvars` | publique par nature : chargée par le navigateur |
| `lyra_endpoint` | `envs/<env>.tfvars` | `https://api.payzen.eu` |
| `lyra_ipn_url` | `envs/<env>.tfvars` | endpoint REACTION de l'API organisme |
| `sentry_dsn` | `envs/prod.secret.tfvars` (gitignoré, chargé par `tf.ps1`) | DSN Sentry, prod seulement ; écriture d'events uniquement mais quota saturable si public |

Quatre pièges à connaître :

1. **Les clés doivent être les mêmes des deux côtés.** L'API organisme vérifie la
   signature de l'IPN avec `WEB_API_REACTION_LYRA_PWD`. Si ce mot de passe diffère
   de `LYRA_PWD`, le client est débité mais la réservation reste en `etat = -3`.
2. **`lyra_public_key` doit désigner la même boutique que `LYRA_USERNAME`**, sinon
   PayZen refuse le formToken. Contrairement à cntp-2026, elle n'est pas inlinée au
   build : elle est lue à l'exécution depuis `LYRA_PK`, donc un apply suffit à la
   corriger.
3. **L'IPN doit pointer sur `...-reaction`**, pas sur `...-cntp` ni `...-lyra` : c'est
   lui qui détermine le mode de paiement écrit sur la réservation.
4. **Le mode test ne se choisit pas par l'URL** mais par le jeu de clés (clés de test
   vs production). L'endpoint est identique.

Tant que `LYRA_USERNAME` / `LYRA_PWD` sont sur leur placeholder, le tunnel affiche
« Paiement non configuré » au lieu de planter : on peut déployer sans les clés.

### 3. Init + plan + apply

```powershell
.\switch-backend.ps1 dev     # ou prod
.\tf.ps1 dev plan
.\tf.ps1 dev apply
```

Les deux scripts existent pour éviter deux pièges de ce poste :

- le collage console insère un octet `0x16` invisible, que Terraform reçoit comme
  un argument positionnel et rejette en « Too many command line arguments » ;
- un `apply` interrompu sur sa question de confirmation sort en `EOF` et laisse un
  lock S3 orphelin (`.\tf.ps1 dev unlock <id>` pour le lever). `plan -out` puis
  `apply <plan>` ne pose aucune question et applique exactement le plan relu.

⚠️ Le dossier de travail ne pointe que sur **un** backend à la fois : après un
`switch-backend.ps1 dev`, rebasculer sur prod avant de planifier la prod, sinon le
plan vise silencieusement le mauvais compte.

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
