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

# Pas de variable rds_password : le mot de passe est injecté dans Secrets Manager
# hors Terraform (cf. secrets.tf), pour qu'il n'entre jamais dans le tfstate.

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
  description = "FQDN public Laravel (ex: dev.reactionpermis.fr). Active cert ACM + listener rule host-based si non vide. DOIT être l'hôte CANONIQUE, celui vers lequel les autres redirigent : il alimente APP_URL (cf. ecs.tf), donc le canonical, og:url, les <loc> du sitemap et la directive Sitemap: du robots.txt. Y mettre un hôte qui répond 301 fait déclarer à toutes les pages une URL canonique redirigée. Les alias (apex, anciens domaines) vont dans app_additional_hosts."
  type        = string
  default     = ""
}

variable "app_additional_hosts" {
  description = "Hosts supplémentaires servis par la même règle que app_fqdn (ex: [\"reactionpermis.fr\"] quand app_fqdn vaut www.reactionpermis.fr). Le certificat doit les couvrir. Utile au go-live : la règle ALB historique (priorité 60) sert apex ET www dans une seule règle, la remplacer sans reprendre les deux enverrait l'hôte oublié sur l'action par défaut de l'ALB, donc sur le site aaaep."
  type        = list(string)
  default     = []
}

variable "app_acm_certificate_domain" {
  description = "Domaine d'un certificat ACM existant couvrant app_fqdn et app_additional_hosts (ex: reactionpermis.fr, si son SAN *.reactionpermis.fr couvre preprod.reactionpermis.fr). Renseigné = ce stack consomme ce certificat sans le créer ni l'attacher au listener — son propriétaire s'en charge. Vide = le stack émet son propre certificat pour app_fqdn. Résolu par nom et non par ARN : le certificat est créé hors Terraform, un ARN en dur casserait s'il était recréé."
  type        = string
  default     = ""
}

variable "app_route53_zone_id" {
  description = "Zone Route53 hébergeant app_fqdn, si elle est dans LE MÊME compte que ce stack. Renseignée = Terraform pose les records de validation ACM, attend l'émission du certificat, et crée l'alias vers l'ALB (apply en une passe). Vide = DNS manuel, seul mode possible quand la zone vit dans un autre compte (cas du dev). À vider au go-live : les records de reactionpermis.fr existent déjà et les adopter rendrait un retour arrière dangereux."
  type        = string
  default     = ""
}

variable "app_listener_rule_priority" {
  description = "Priorité listener rule app sur le 443 (1-50000, unique sur ce listener). ⚠️ la priorité +1 est aussi réservée (règle 403 du mode pré-prod verrouillée)."
  type        = number
  default     = 200
}

variable "app_allowed_source_ips" {
  description = <<-EOT
    Mode pré-prod verrouillée : liste de CIDR autorisés à accéder au FQDN
    (ex: ["203.0.113.42/32"]). Non vide = la listener rule exige Host ET IP
    source, et une règle 403 (priorité +1) bloque tout le reste du trafic de
    ce Host. Vide (défaut) = accès public normal — c'est l'état go-live.
    NB : l'ALB voit l'IP publique du client (pas de proxy devant), donc un /32
    par poste/bureau suffit. L'IP du poste change (FAI non fixe) : la
    re-vérifier à chaque session, sinon on se verrouille soi-même dehors.
  EOT
  type        = list(string)
  default     = []
}

variable "github_deploy_branch_patterns" {
  description = "Branches autorisées à assumer le rôle de déploiement de cet environnement (patterns de sub OIDC, joker * accepté). Défaut permissif pour ne pas casser le dev ; la prod restreint aux seules branches qui déclenchent un déploiement."
  type        = list(string)
  default     = ["*"]
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

# ─── Paiement Lyra / PayZen ───────────────────────────────────────────────────
#
# La boutique utilisée est celle de Réaction Permis. Point de vigilance majeur :
# les MÊMES identifiants doivent être configurés côté API organisme sous
# `WEB_API_REACTION_LYRA_*`, car c'est avec ce mot de passe que l'IPN vérifie la
# signature `kr-hash` du retour de paiement. Deux jeux de clés différents = le
# client est débité mais la réservation n'est jamais confirmée en base.
#
# Répartition volontaire :
#   - username + password → Secrets Manager HORS Terraform : secret partagé
#                           shared/<env>/lyra-rp si shared_secrets_env est posé
#                           (shared_secrets.tf), secret applicatif sinon (secrets.tf).
#                           Pas de variable ici, sinon la valeur transiterait par le
#                           tfstate
#   - public key          → secret partagé avec les deux autres si shared_secrets_env
#                           est posé, env var simple sinon (lyra_public_key) : elle
#                           est envoyée au NAVIGATEUR par Krypton, ce n'est pas un secret
#   - endpoint + IPN      → env vars simples, ce sont des URLs de configuration

variable "shared_secrets_env" {
  description = <<-EOT
    Environnement des secrets partagés de aaaep-shared-infra à lire (shared/<env>/lyra-rp),
    par exemple "dev". null = pas de secret partagé : identifiants Lyra lus dans le secret
    applicatif et LYRA_PK dans lyra_public_key. Ne le poser qu'une fois aaaep-shared-infra
    appliqué dans ce compte ET la valeur poussée (secrets.ps1 status à ok) : sinon le plan
    échoue (data source introuvable) ou la task ne démarre pas (secret sans version).
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.shared_secrets_env == null || contains(["dev", "prod"], coalesce(var.shared_secrets_env, "dev"))
    error_message = "shared_secrets_env vaut null, \"dev\" ou \"prod\"."
  }
}

variable "shared_brevo_env" {
  description = <<-EOT
    Environnement du secret partagé shared/<env>/brevo-aaaep (clé API Brevo), indépendamment de
    shared_secrets_env (qui pilote Lyra). null = suit shared_secrets_env : en dev il vaut donc
    "dev" sans rien poser. Sert à la prod, où Lyra reste dans le secret applicatif mais où la
    clé Brevo est lue dans le secret partagé. Mêmes prérequis que shared_secrets_env.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.shared_brevo_env == null || contains(["dev", "prod"], coalesce(var.shared_brevo_env, "dev"))
    error_message = "shared_brevo_env vaut null, \"dev\" ou \"prod\"."
  }
}

variable "lyra_public_key" {
  description = "Clé publique Lyra (LYRA_PK), utilisée seulement si shared_secrets_env = null. Publique par nature : chargée côté navigateur par le formulaire Krypton."
  type        = string
  default     = ""
}

variable "lyra_endpoint" {
  description = "Endpoint API Lyra. Le mode test ne se choisit PAS par l'URL mais par le jeu de clés (clés de test vs production)."
  type        = string
  default     = "https://api.payzen.eu"
}

variable "lyra_ipn_url" {
  description = <<-EOT
    URL de notification (IPN) appelée par Lyra après paiement. DOIT pointer sur
    l'endpoint REACTION de l'API organisme, jamais sur celui de CNTP ou d'AAAEP :
    c'est ce qui détermine le mode de paiement posé sur la réservation
    (MP_SITE_LYRA_CONFIRMED_REACTION).
  EOT
  type        = string
  default     = "https://organisme.aaaep.fr/api/api/v3/reservations-paiement-reaction"
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

# ─── Sentry (suivi d'erreurs) ─────────────────────────────────────────────────
#
# Le DSN n'est pas un secret au sens strict (il n'autorise que l'ÉCRITURE
# d'events, jamais la lecture), mais un DSN public permet de saturer le quota
# mensuel du projet. Il ne vit donc ni dans envs/<env>.tfvars (commités, cf.
# .gitignore) ni dans Secrets Manager : ecs.tf référence les clés de ce secret
# une par une et ECS refuse de démarrer la task si l'une manque, ce qui
# transformerait un simple oubli de DSN en site hors ligne.
#
# Prod seulement : ecs.tf ne l'injecte que si local.is_prod. Lu depuis
# envs/prod.secret.tfvars (gitignoré, passé en second -var-file par tf.ps1 s'il
# existe). Vide = variable absente de la task = SDK inerte côté Laravel.
variable "sentry_dsn" {
  description = "DSN Sentry (SENTRY_LARAVEL_DSN). Vide = Sentry désactivé. Prod seulement, fourni via envs/prod.secret.tfvars."
  type        = string
  default     = ""
  # `sensitive` masque la valeur dans la sortie de plan/apply. Elle reste lisible
  # dans le tfstate (comme toute env var de la task) : le bucket state est privé.
  sensitive = true
}
