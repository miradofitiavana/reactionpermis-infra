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
}

# ─── Paiement Lyra / PayZen ───────────────────────────────────────────────────
#
# ⚠️ Utiliser les clés de TEST de la boutique sur cet environnement. Le mode test
# ne se choisit pas par l'URL (endpoint identique) mais par le jeu de clés.
#
# ⚠️ La réservation, elle, est écrite dans l'Aurora du compte dev — pas dans celle
# de la prod. En revanche `lyra_ipn_url` ci-dessous pointe sur l'API organisme de
# PRODUCTION : c'est elle qui reçoit la notification de paiement. Le confirmer
# avant tout test d'encaissement de bout en bout.
#
# username + password → injectés dans Secrets Manager par put-secret-value, jamais
# dans ce fichier ni dans le tfstate. Voir secrets.tf.
lyra_public_key = "84578459:testpublickey_bQosKbpwsFMgwNaX0F7GUsxSgOgTwJUEO4XuIoRmgj5Fr" # clé publique de la boutique de test, à remplir
lyra_endpoint   = "https://api.payzen.eu"
# Endpoint REACTION de l'API organisme. Pointer ailleurs ferait enregistrer le
# paiement sous une autre marque.
lyra_ipn_url = "https://organisme.aaaep.fr/api/api/v3/reservations-paiement-reaction"

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
