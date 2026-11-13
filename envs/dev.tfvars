environment = "dev"

# ─── Réseau : VPC aaaep (partagé avec site-web et Aurora) ─────────────────────
vpc_id              = "vpc-055d45f9de7e2604d"
ecs_task_subnet_ids = ["subnet-069e6e829ad93c508", "subnet-065956d0de20cc443"]
efs_subnet_ids      = ["subnet-069e6e829ad93c508", "subnet-065956d0de20cc443"]
# Subnets aaaep sans NAT : tasks prennent une IP publique pour pull ECR + S3.
assign_public_ip_to_tasks = true

# ─── Aurora MySQL du compte DEV (aaaep-db-mysql) ──────────────────────────────
# Cluster distinct de celui de la prod (aaaep-db-mysql-v1-cluster, compte
# 381492212876). Les deux portent une base nommée `aaaep_aaaeporganisme`, ce qui
# rend la confusion facile : ce sont deux jeux de données séparés.
rds_security_group_id = "sg-0c57e83bf13e00abe"
rds_endpoint          = "aaaep-db-mysql.cluster-c5wkoiyq2p0n.eu-west-3.rds.amazonaws.com"
rds_port              = 3306
# Base mutualisée entre applications DANS le compte dev. Nos tables sont
# préfixées rp2026_ pour cohabiter sans collision avec les tables legacy
# (medecin_infos, etc.).
rds_database_name = "aaaep_aaaeporganisme"
# User MySQL existant partagé avec reactionpermis-back (pas de user dédié rp2026
# pour l'instant - voir si on en crée un plus tard pour scoper les droits).
rds_username = "aaaep_aaaeporganisme"
# Mot de passe : plus de TF_VAR_rds_password. Il est injecté dans Secrets Manager
# hors Terraform (cf. secrets.tf), pour ne pas transiter par le tfstate.

# ─── ALB partagé (aaaep-site-web-alb) ─────────────────────────────────────────
shared_alb_arn                = "arn:aws:elasticloadbalancing:eu-west-3:211125435907:loadbalancer/app/aaaep-site-web-alb/0003056da10b86b2"
shared_alb_security_group_id  = "sg-04fdb42c0d09a1967"
shared_alb_listener_https_arn = "arn:aws:elasticloadbalancing:eu-west-3:211125435907:listener/app/aaaep-site-web-alb/0003056da10b86b2/8c93cfbd883bfa75"
shared_alb_listener_http_arn  = "arn:aws:elasticloadbalancing:eu-west-3:211125435907:listener/app/aaaep-site-web-alb/0003056da10b86b2/9f7e4c3f633911e1"

# ─── FQDN public Laravel ──────────────────────────────────────────────────────
app_fqdn                   = "dev.reactionpermis.fr"
app_listener_rule_priority = 200

# ─── App Laravel / ECS ────────────────────────────────────────────────────────
app_image_tag      = "latest"
app_cpu            = 512
app_memory         = 1024
app_desired_count  = 1
app_container_port = 8080
log_retention_days = 14

app_env = "production" # dev = environnement AWS, mais APP_ENV reste 'production' pour exercer le bon code path
# false = optimisations runtime activées (no Ignition overhead, no stack tracing
# sur 500). En cas de debug, set à true temporairement + apply + REMETTRE à false.
app_debug = false

# Env vars supplémentaires (overrides + extensions sans modifier ecs.tf)
app_extra_env = {
  # Force noindex sur staging même avec APP_ENV=production.
  # Layout app.blade.php inject <meta name="robots" content="noindex,nofollow">.
  # À PASSER À "false" si on veut indexer ce déploiement (jamais en dev).
  APP_NOINDEX = "true"

  APP_LOCALE = "fr"

  # Les identifiants des gabarits Brevo sont des valeurs par défaut de config/brevo.php
  # (même compte AAAEP en dev et en prod) : les surcharger ici seulement si besoin.

  # Tous les envois vont vers BREVO_TEST_MAIL : la dev ne doit jamais écrire à un vrai compte.
  BREVO_TEST_OVERRIDE_ENABLED = "true"
  BREVO_TEST_MAIL             = "mirado@aaaep.fr"
}

# ─── Paiement Lyra / PayZen ───────────────────────────────────────────────────
#
# ⚠️ Utiliser les clés de TEST de la boutique sur cet environnement. Le mode test
# ne se choisit pas par l'URL (endpoint identique) mais par le jeu de clés.
#
# Identifiant, mot de passe ET clé publique viennent du secret partagé
# shared/dev/lyra-rp (aaaep-shared-infra), le même que lit l'API organisme dev pour
# vérifier le kr-hash de l'IPN (WEB_API_REACTION_LYRA_PWD) : une seule copie, donc
# plus de désynchronisation possible entre les deux. lyra_public_key n'est plus lu ici.
shared_secrets_env = "dev"
lyra_endpoint      = "https://api.payzen.eu"
# Endpoint REACTION de l'API organisme DE DEV (ECS, Laravel à la racine du domaine :
# un seul /api, contrairement à l'EC2 de prod en /api/api). La réservation est écrite
# dans l'Aurora du compte dev : la notification doit arriver à l'API qui lit cette
# base. Viser la prod ferait valider, avec un paiement de test, la réservation de
# prod portant le même id. Pointer sur un autre endpoint que -reaction ferait en
# outre enregistrer le paiement sous une autre marque.
lyra_ipn_url = "https://dev-organisme.aaaep.fr/api/v3/reservations-paiement-reaction"

# ─── Auto start/stop ECS (économie hors heures travail) ──────────────────────
# Lun-Ven 7h30 → start, Lun-Ven 23h30 → stop. Weekend = restera off.
# Au démarrage prévoir ~30s pour que la task soit healthy + servie par l'ALB.
app_schedule_enabled    = true
app_schedule_timezone   = "Europe/Paris"
app_schedule_start_cron = "cron(30 7 ? * MON-FRI *)"
app_schedule_stop_cron  = "cron(30 23 ? * MON-FRI *)"

# ─── EFS ──────────────────────────────────────────────────────────────────────
efs_performance_mode = "generalPurpose"
efs_throughput_mode  = "bursting"
