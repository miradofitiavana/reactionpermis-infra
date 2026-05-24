# Variables d'entrée — alimentées via envs/<env>.tfvars + TF_VAR_* env vars.

# ─── Généraux ─────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "Région AWS de déploiement (Aurora + ALB sont en eu-west-3)."
  type        = string
  default     = "eu-west-3"
}

variable "project_name" {
  description = "Préfixe commun de toutes les ressources AWS."
  type        = string
  default     = "reactionpermis"
}

variable "environment" {
  description = "Identifiant d'environnement (dev/prod)."
  type        = string
  default     = "dev"
}

# ─── Réseau ───────────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = "VPC où tournent l'ALB aaaep, l'Aurora partagée, et où on lancera ECS+EFS."
  type        = string
}

variable "ecs_task_subnet_ids" {
  description = "Subnets pour les tasks ECS Fargate (≥ 2 AZ). En VPC aaaep : subnets publics avec assign_public_ip=true."
  type        = list(string)
}

variable "efs_subnet_ids" {
  description = "Subnets où créer les mount targets EFS (un par AZ, idéalement les mêmes que les tasks ECS)."
  type        = list(string)
}

variable "assign_public_ip_to_tasks" {
  description = "true si les subnets ECS n'ont pas de NAT (les tasks prennent une IP publique pour pull ECR + S3)."
  type        = bool
  default     = true
}

# ─── Aurora MySQL partagé ─────────────────────────────────────────────────────

variable "rds_security_group_id" {
  description = "SG attaché à l'Aurora aaaep. TF y ajoute un ingress depuis le SG ECS app."
  type        = string
}

variable "rds_endpoint" {
  description = "Endpoint writer du cluster Aurora (sans port). Ex: aaaep-db-mysql.cluster-xxx.eu-west-3.rds.amazonaws.com"
  type        = string
}

variable "rds_port" {
  type    = number
  default = 3306
}

variable "rds_database_name" {
  description = "Base logique dédiée Laravel dans l'Aurora. Note: les tables sont préfixées rp2026_ pour cohabiter avec d'autres apps sur la même base."
  type        = string
}

variable "rds_username" {
  description = "User MySQL Laravel (créé manuellement sur l'Aurora, cf README)."
  type        = string
}

variable "rds_password" {
  description = "Password du user MySQL Laravel. Stocké dans Secrets Manager. Préférer TF_VAR_rds_password."
  type        = string
  sensitive   = true
}

# ─── ALB mutualisé (aaaep-site-web-alb) ───────────────────────────────────────

variable "shared_alb_arn" {
  description = "ARN de l'ALB aaaep. TF n'en crée pas, il ajoute juste un TG + listener rule."
  type        = string
}

variable "shared_alb_security_group_id" {
  description = "SG de l'ALB partagé. Référencé dans le SG des tasks app (ingress 8080)."
  type        = string
}

variable "shared_alb_listener_https_arn" {
  description = "ARN du listener 443 HTTPS de l'ALB partagé. Requis quand app_fqdn est renseigné."
  type        = string
  default     = ""
}

variable "shared_alb_listener_http_arn" {
  description = "ARN du listener 80 HTTP de l'ALB partagé. Si renseigné avec app_fqdn, redirect 80→443."
  type        = string
  default     = ""
}

variable "app_fqdn" {
  description = "FQDN public Laravel (ex: dev.reactionpermis.fr). Active cert ACM + listener rule host-based si non vide."
  type        = string
  default     = ""
}

variable "app_listener_rule_priority" {
  description = "Priorité listener rule app sur le 443 (1-50000, unique sur ce listener)."
  type        = number
  default     = 200
}

# ─── Laravel app / ECS ────────────────────────────────────────────────────────

variable "app_image_tag" {
  description = "Tag Docker dans ECR. 'latest' en dev, tag immuable en prod (ex: prod-2026-05-24-abc1234)."
  type        = string
  default     = "latest"
}

variable "app_cpu" {
  description = "Unités CPU Fargate (1024 = 1 vCPU). Valides : 256, 512, 1024, 2048, 4096."
  type        = number
  default     = 512
}

variable "app_memory" {
  description = "Mémoire Fargate en MiB. Doit être compatible avec cpu (cf docs Fargate)."
  type        = number
  default     = 1024
}

variable "app_desired_count" {
  description = "Nombre de tasks app simultanées. 1 en dev, 2+ en prod (HA)."
  type        = number
  default     = 1
}

variable "app_container_port" {
  description = "Port HTTP exposé par nginx dans le conteneur. ALB forward dessus."
  type        = number
  default     = 8080
}

variable "log_retention_days" {
  description = "Rétention CloudWatch Logs ECS app."
  type        = number
  default     = 14
}

# ─── App-level config (env vars Laravel non-secrètes) ─────────────────────────

variable "app_env" {
  description = "APP_ENV Laravel (local/staging/production)."
  type        = string
  default     = "production"
}

variable "app_debug" {
  description = "APP_DEBUG Laravel. false en prod, true en dev éventuellement."
  type        = bool
  default     = false
}

variable "app_extra_env" {
  description = "Env vars non-secrètes additionnelles à injecter dans la task (overrides + extensions)."
  type        = map(string)
  default     = {}
}

# ─── Auto start/stop ECS (économie hors heures de travail) ───────────────────

variable "app_schedule_enabled" {
  description = "Active 2 EventBridge schedules cron pour stop/start ECS auto (économie ~60% en dev). Laisser false en prod."
  type        = bool
  default     = false
}

variable "app_schedule_timezone" {
  description = "Timezone des cron (cf liste IANA). Ex: 'Europe/Paris', 'UTC'."
  type        = string
  default     = "Europe/Paris"
}

variable "app_schedule_start_cron" {
  description = "Cron de démarrage (desired_count=1). Format AWS : cron(min hour day-of-month month day-of-week year)."
  type        = string
  default     = "cron(0 7 ? * MON-FRI *)" # 7h, lundi-vendredi
}

variable "app_schedule_stop_cron" {
  description = "Cron d'arrêt (desired_count=0). Idem syntax."
  type        = string
  default     = "cron(0 22 ? * MON-FRI *)" # 22h, lundi-vendredi
}

# ─── EFS (cache HTML + sessions partagés entre tasks) ─────────────────────────

variable "efs_performance_mode" {
  description = "Mode de perf EFS. 'generalPurpose' (latence faible, suffisant) ou 'maxIO' (débit énorme, rare)."
  type        = string
  default     = "generalPurpose"
}

variable "efs_throughput_mode" {
  description = "Mode de débit EFS. 'bursting' (gratuit, suffit pour cache HTML), 'elastic' (premium si bursts longs)."
  type        = string
  default     = "bursting"
}
