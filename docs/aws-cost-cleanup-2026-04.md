# AWS cost cleanup — avril 2026

Journal de nettoyage du compte AWS `211125435907` (région `eu-west-3`), env dev.

## Point de départ

Facture ~594 $/mois, dominée par :

| Poste | $/mois |
|---|---|
| ECS Fargate | 217 |
| Tax | 99 |
| RDS | 64 |
| ELB (ALBs) | 53 |
| VPC (NAT Gateway) | 48 |
| EC2 instances + EC2-Other | 54 |
| CloudWatch | 31 |
| ECR | 12 |
| Autres | ~16 |

## Inventaire initial ECS

Deux clusters, 6 services Fargate :

| Cluster | Service | CPU | Mem (MiB) | État |
|---|---|---|---|---|
| claryvoo-dev-cluster | claryvoo-dev-backend-service | 512 | 1024 | keep |
| claryvoo-dev-cluster | claryvoo-dev-frontend-service | 256 | 512 | keep |
| aaaep-site-web-dev-cluster | mcp-server | 512 | 1024 | keep |
| aaaep-site-web-dev-cluster | aaaep-site-web-dev-service | 1024 | 4096 | keep (à downsize) |
| aaaep-site-web-dev-cluster | aaaep-blog-dev-service | 1024 | 4096 | **supprimé** |
| aaaep-site-web-dev-cluster | aaaep-site-carriere-dev-service | 1024 | 4096 | **supprimé** |

## Actions réalisées

### 1. Suppression services obsolètes
```bash
aws ecs update-service --cluster aaaep-site-web-dev-cluster --service aaaep-blog-dev-service --desired-count 0 --region eu-west-3
aws ecs update-service --cluster aaaep-site-web-dev-cluster --service aaaep-site-carriere-dev-service --desired-count 0 --region eu-west-3
aws ecs delete-service --cluster aaaep-site-web-dev-cluster --service aaaep-blog-dev-service --region eu-west-3
aws ecs delete-service --cluster aaaep-site-web-dev-cluster --service aaaep-site-carriere-dev-service --region eu-west-3
```
**Gain : -85 $/mois**

### 2. Cleanup ressources liées
```bash
# Log groups
aws logs delete-log-group --log-group-name "/aws/ecs/aaaep-blog-dev-service/aaaep-blog" --region eu-west-3
aws logs delete-log-group --log-group-name "/aws/ecs/aaaep-site-carriere-dev-service/aaaep-site-carriere" --region eu-west-3

# ECR repos
aws ecr delete-repository --repository-name aaaep-blog-dev --force --region eu-west-3
aws ecr delete-repository --repository-name aaaep-site-carriere-dev --force --region eu-west-3

# Target groups orphelins
aws elbv2 delete-rule --rule-arn <rule-blog-listener-80>
aws elbv2 delete-rule --rule-arn <rule-blog-listener-443>
aws elbv2 delete-target-group --target-group-arn <tf-20240807092808138100000001>
aws elbv2 delete-target-group --target-group-arn <tf-20250307150911042200000006>

# ALB dédié carriere
aws elbv2 delete-load-balancer --load-balancer-arn <aaaep-site-carriere-alb>
```
**Gain : -20 $/mois (1 ALB + stockage ECR)**

### 3. Migration claryvoo vers subnets publics + suppression NAT Gateway

Claryvoo tournait en subnets privés derrière un NAT Gateway (32 $/mois fixe + data). Les SG des tasks ne laissent rentrer que l'ALB (pas de `0.0.0.0/0`), donc bascule en subnets publics avec `assignPublicIp=ENABLED` sans perte de sécurité.

```bash
# Frontend
aws ecs update-service --cluster claryvoo-dev-cluster --service claryvoo-dev-frontend-service \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-09ec6b0308bd1313c,subnet-0772451d6bc5e49b6],assignPublicIp=ENABLED,securityGroups=[sg-052b002f8f3ff76e2]}" \
  --force-new-deployment --region eu-west-3

# Backend
aws ecs update-service --cluster claryvoo-dev-cluster --service claryvoo-dev-backend-service \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-09ec6b0308bd1313c,subnet-0772451d6bc5e49b6],assignPublicIp=ENABLED,securityGroups=[sg-0d6e04ee42f95cba6]}" \
  --force-new-deployment --region eu-west-3

# Suppression NAT + release EIP
aws ec2 delete-nat-gateway --nat-gateway-id nat-0209f4dd8609e0816 --region eu-west-3
aws ec2 release-address --allocation-id <eipalloc-xxx> --region eu-west-3
aws ec2 delete-route --route-table-id rtb-0e45774798de92ed0 --destination-cidr-block 0.0.0.0/0 --region eu-west-3
```
**Gain : ~-35 $/mois (32 $ NAT + 3,6 $ EIP)**

## Bilan

| Action | Gain/mois |
|---|---|
| Services ECS blog + carriere | -85 $ |
| Log groups + ECR associés | -2 $ |
| ALB carriere + target groups orphelins | -18 $ |
| NAT Gateway + EIP | -35 $ |
| **Total** | **~-140 $/mois** |

Facture projetée : **~455 $/mois** (vs 594 $ avant).

## Topologie VPC finale

- **VPC claryvoo** (`vpc-0607226ddeafd2328`) : RDS en database subnets, ECS en public subnets (plus de NAT).
- **VPC aaaep** (`vpc-055d45f9de7e2604d`) : ECS en public subnets avec `assignPublicIp=ENABLED`. Pas de NAT.

Les SG de toutes les tasks restreignent l'inbound au seul SG ALB correspondant → pas d'exposition directe depuis Internet.

## Pistes restantes (non faites)

| Action | Gain potentiel |
|---|---|
| Downsize `aaaep-site-web-dev-service` 1024/4096 → 512/2048 | ~-20 $ |
| Vérif sizing RDS + classe d'instance | variable |
| EC2 instances + EBS volumes orphelins (54 $) | variable |
| CloudWatch rétention logs (31 $) | ~-10 à -20 $ |
| AWS Config (7 $) si pas de besoin compliance en dev | -7 $ |
| Secrets Manager audit orphelins | ~-2 à -5 $ |
| Fargate Spot sur les services dev (interruption tolérée) | jusqu'à -50 % ECS |
| Scheduled scaling (arrêt nuit + WE) | -50 % sur services arrêtés |
