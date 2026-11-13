# Environnement PROD (compte aaaep prod 381492212876) - phase GO-LIVE.
#
# Le stack sert désormais www.reactionpermis.fr + l'apex, sans verrou par IP.
# L'apply de ces valeurs n'a AUCUN effet visible tant que la règle ALB historique
# de priorité 60 existe : l'ALB évalue par priorité croissante et 60 gagne sur
# notre 200. La bascule elle-même est la suppression de cette règle 60, à faire
# après vérification des cibles saines (cf. RUNBOOK-golive-rp.md §4 et §5).
#
# Retour en pré-prod verrouillée, si besoin :
#   app_fqdn = "preprod.reactionpermis.fr", app_additional_hosts = [],
#   app_route53_zone_id = "Z0640180MSVICF0UZFEL", APP_NOINDEX = "true",
#   app_allowed_source_ips = ["<ip du poste>/32"]
#
# Valeurs réseau/ALB/RDS reprises de la topologie prod relevée le 2026-08-12 pour
# cntp-2026 (même VPC, même ALB, même Aurora). À RE-CONFIRMER à la CLI avant le
# premier apply : cf. §0 du runbook.

project_name = "reactionpermis"
environment  = "prod"

# ─── Réseau : VPC aaaep prod ──────────────────────────────────────────────────
vpc_id = "vpc-04be4d57ab9e2d3b7" # aaaep-vpc 10.0.0.0/16

# Subnets 3a/3b, associés à rtb-00ac8b8d83b25c259 qui route 0.0.0.0/0 vers
# igw-0fe6bcd042b0e481a (vérifié 2026-08-25). C'est ce routage, et lui seul, qui
# fait qu'une task peut tirer son image ECR : ces subnets sont en
# `MapPublicIpOnLaunch = false`, mais ECS passe `assignPublicIp = ENABLED` dans la
# configuration réseau de la task, ce qui l'emporte sur le défaut du subnet.
#
# Le compte prod n'a PAS de NAT Gateway. La route table principale du VPC ne porte
# que la route locale : un subnet privé y est un cul-de-sac, une task n'y
# démarrerait jamais. Modèle retenu = subnet routé vers l'IGW + IP publique + SG
# verrouillé (aucun ingress hors du SG de l'ALB).
ecs_task_subnet_ids       = ["subnet-0e04aeb06be6c29d6", "subnet-0a56ed7583cb9b247"]
efs_subnet_ids            = ["subnet-0e04aeb06be6c29d6", "subnet-0a56ed7583cb9b247"]
assign_public_ip_to_tasks = true

# ─── Aurora MySQL prod (base métier live) ─────────────────────────────────────
# Cluster aaaep-db-mysql-v1 : c'est la base métier partagée. Les tables rp2026_*
# doivent y être créées AVANT le premier démarrage des tasks (les migrations ne
# sont pas jouées par le conteneur, cf. docker/entrypoint.sh).
rds_security_group_id = "sg-063128012092f8123" # rds-ec2-1 (3306 fermé au VPC, TF ajoute l'ingress depuis le SG app)
rds_endpoint          = "aaaep-db-mysql-v1-cluster.cluster-czgeooyaa7fo.eu-west-3.rds.amazonaws.com"
rds_port              = 3306
rds_database_name     = "aaaep_aaaeporganisme"
# User dédié à l'app (convention 2026-08-05 : un user MySQL par application, pour
# rendre la consommation attribuable et plafonner les connexions sur un cluster
# partagé). Sans droit DDL : les migrations tournent à la main avec le user commun.
# Création + GRANT : docs/2026-08-25-user-mysql-rp2026.sql
rds_username = "rp2026"
# Mot de passe : pas de TF_VAR. Injecté dans Secrets Manager par put-secret-value
# (runbook §2) pour rester hors du tfstate.

# ─── ALB partagé prod (aaaep-site-web-alb, compte 381492212876) ───────────────
# Même ALB qui sert DÉJÀ reactionpermis.fr : le go-live consistera à basculer le
# host vers notre target group en supprimant la règle historique.
shared_alb_arn                = "arn:aws:elasticloadbalancing:eu-west-3:381492212876:loadbalancer/app/aaaep-site-web-alb/da203a6f6728345c"
shared_alb_security_group_id  = "sg-0329ff1e91151e154"
shared_alb_listener_https_arn = "arn:aws:elasticloadbalancing:eu-west-3:381492212876:listener/app/aaaep-site-web-alb/da203a6f6728345c/e4bbf9f610ffb951"
# Listener 80. L'ALB n'a PAS de redirect HTTP→HTTPS global : son action par défaut
# est un forward. Sans la règle posée par ce stack, le port 80 de notre host
# tomberait sur le site aaaep par défaut, hors du verrou par IP.
shared_alb_listener_http_arn = "arn:aws:elasticloadbalancing:eu-west-3:381492212876:listener/app/aaaep-site-web-alb/da203a6f6728345c/1391cfd4ea9deb2b"

# ─── FQDN ─────────────────────────────────────────────────────────────────────
# L'hôte CANONIQUE est www, et non l'apex : app_fqdn n'alimente pas que le
# routage, il alimente APP_URL, d'où Laravel tire les canonical, og:url et les
# <loc> du sitemap. Or docker/nginx.conf renvoie l'apex nu en 301 vers www. Mettre
# l'apex ici ferait déclarer à chaque page une URL canonique redirigée, un défaut
# invisible : le site répondrait 200 partout.
#
# Les deux hôtes tiennent dans la MÊME règle de listener (concat de app_fqdn et
# app_additional_hosts), comme la règle 60 qu'on remplace.
app_fqdn             = "www.reactionpermis.fr"
app_additional_hosts = ["reactionpermis.fr"]

# Vide au go-live, volontairement : les records de reactionpermis.fr et de
# www.reactionpermis.fr existent déjà et sont gérés hors Terraform depuis toujours.
# Les adopter n'apporterait rien et rendrait un retour arrière dangereux, une
# erreur sur cet état supprimant l'apex du domaine.
#
# Effet de bord VOULU : l'alias preprod.reactionpermis.fr posé par ce stack est
# détruit à l'apply. La zone reste Z0640180MSVICF0UZFEL si on doit y revenir.
app_route53_zone_id = ""

# Certificat de la fondation, créé hors Terraform. Relevé le 2026-08-25 :
# arn:…:certificate/a015d790-a196-4d2b-82ca-739d469d5ea0, ISSUED, SAN
# [reactionpermis.fr, *.reactionpermis.fr, www.reactionpermis.fr], déjà attaché à
# aaaep-site-web-alb. Le wildcard couvre preprod.reactionpermis.fr aujourd'hui ET
# l'apex + www au go-live : cette variable ne changera pas.
#
# Renseignée, ce stack CONSOMME le certificat sans le posséder : pas d'émission,
# et surtout pas d'`aws_lb_listener_certificate` de notre côté. Le déclarer ferait
# gérer la même ressource par deux états, et un destroy chez nous détacherait le
# certificat qui sert le site de production.
app_acm_certificate_domain = "reactionpermis.fr"

# Bloc 200-209 réservé à reactionpermis-2026 dans le registre des priorités ALB.
# 200 = forward, 201 = règle 403 du verrou (prise implicitement).
app_listener_rule_priority = 200

# Liste vide = site public. Concrètement, l'apply retire la condition source_ip
# des deux règles de forward (443 et 80) et DÉTRUIT les deux règles 403 qui les
# doublaient (leur count tombe à 0).
app_allowed_source_ips = []

# Branches autorisées à déployer sur cet environnement (trust policy OIDC). Doit
# rester aligné avec les triggers de deploy.yml : main et release/**. Un
# workflow_dispatch depuis une autre branche échouera à l'assume role — c'est
# voulu, la cible est la production.
github_deploy_branch_patterns = ["main", "release/*"]

# ─── App Laravel / ECS ────────────────────────────────────────────────────────
# Dimensionnement de production dès la pré-prod, volontairement : le go-live ne
# doit changer QUE les conditions de routage. Modifier en même temps la forme du
# calcul ajouterait un facteur de risque à l'instant le plus critique.
# 1 task depuis le 2026-10-22 (coût ; charge mesurée : CPU moyen 2-4 %, mémoire
# max 42 % sur 2 tasks). Pas de redondance : une task qui tombe coupe le site le
# temps d'un redémarrage. Le déploiement reste sans coupure (min 100 % / max 200 %).
# `desired_count` est dans `ignore_changes` (ecs.tf) : ce fichier ne pilote pas le
# service en place, le réglage réel passe par `aws ecs update-service`.
app_image_tag      = "latest" # le workflow pousse <env>-<sha>-<ts> ET latest, puis force-new-deployment
app_cpu            = 1024
app_memory         = 2048
app_desired_count  = 1
app_container_port = 8080
log_retention_days = 90

app_env   = "production"
app_debug = false

app_extra_env = {
  # Verrou SEO levé pour le go-live. À "true", le layout injecte
  # <meta name="robots" content="noindex,nofollow"> sur TOUTES les pages : le site
  # répondrait 200 partout tout en sortant de l'index Google.
  #
  # public/robots.txt est un fichier STATIQUE : cette variable n'agit que sur la
  # balise meta, il n'y a pas de second filet côté robots.txt.
  APP_NOINDEX = "false"

  APP_LOCALE = "fr"

  # Les identifiants des gabarits Brevo sont des valeurs par défaut de config/brevo.php
  # (même compte AAAEP en dev et en prod) : les surcharger ici seulement si besoin.

  # Le repasser à "true" détournerait les vraies invitations vers BREVO_TEST_MAIL.
  BREVO_TEST_OVERRIDE_ENABLED = "false"
}

# Clé API Brevo lue dans shared/prod/brevo-aaaep (aaaep-shared-infra). Lyra reste, elle, dans
# le secret applicatif : shared_secrets_env n'est volontairement pas posé en prod.
shared_brevo_env = "prod"

# ─── Auto start/stop ECS ──────────────────────────────────────────────────────
# ⚠️ IMPÉRATIVEMENT false en prod : ces schedules mettent desired_count à 0 tous
# les soirs. Explicite ici plutôt que laissé au défaut, parce qu'une copie
# distraite depuis dev.tfvars éteindrait le site toutes les nuits.
app_schedule_enabled = false

# ─── EFS ──────────────────────────────────────────────────────────────────────
efs_performance_mode = "generalPurpose"
efs_throughput_mode  = "elastic" # bursts de cache réponse possibles en prod

# ─── Paiement Lyra / PayZen (non secret) ──────────────────────────────────────
# username/pwd = injectés dans Secrets Manager hors Terraform (runbook §2).
# ⚠️ Clé PUBLIQUE de PRODUCTION de la boutique Réaction Permis (format
# `publickey_`, par opposition au `testpublickey_` des boutiques de test). Elle
# doit désigner la même boutique que LYRA_USERNAME, sinon PayZen refuse le
# formToken. Associée à de vraies credentials API, un paiement lancé depuis cette
# pré-prod serait un VRAI débit et créerait une vraie ligne dans
# organisme_reservations — la base est celle de la production.
lyra_public_key = "66814436:publickey_GJb290e39Fsqyh7cJHuVRlcKELl4a88SmJ3hi84EjZ6bK"
lyra_endpoint   = "https://api.payzen.eu"
# Endpoint REACTION de l'API organisme : c'est lui qui pose
# MP_SITE_LYRA_CONFIRMED_REACTION sur la réservation. Pointer ailleurs ferait
# enregistrer le paiement sous une autre marque.
lyra_ipn_url = "https://organisme.aaaep.fr/api/api/v3/reservations-paiement-reaction"
