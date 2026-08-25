# Environnement PROD (compte aaaep prod 381492212876) — phase « pré-prod verrouillée ».
#
# Stratégie : on provisionne l'infra prod DÉFINITIVE, mais exposée sur
# preprod.reactionpermis.fr et restreinte par IP (app_allowed_source_ips). Le
# site public reactionpermis.fr continue d'être servi par la règle ALB historique
# (priorité 60) pendant toute cette phase. Au go-live :
#   1. app_fqdn → www.reactionpermis.fr, app_additional_hosts → ["reactionpermis.fr"]
#   2. app_allowed_source_ips → []
#   3. app_acm_certificate_domain → "reactionpermis.fr" (on cesse d'émettre le nôtre)
#   4. app_route53_zone_id → "" (les records existent déjà, on ne les adopte pas)
#   5. app_extra_env : APP_NOINDEX → "false"
#   6. apply (sans effet visible : 60 < 200, l'ancienne règle gagne), vérifier,
#      PUIS supprimer la règle 60 — c'est ça, la bascule.
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
# Phase pré-prod. Au go-live ce sera "www.reactionpermis.fr" (l'hôte CANONIQUE :
# l'apex répond 301 vers www aujourd'hui, et app_fqdn alimente APP_URL donc les
# canonical/og:url/sitemap — y mettre l'apex ferait déclarer à toutes les pages
# une URL canonique redirigée).
app_fqdn             = "preprod.reactionpermis.fr"
app_additional_hosts = []

# Zone Route53 reactionpermis.fr du compte prod (relevée 2026-08-25, 20 records).
# Renseignée, Terraform pose le record preprod + les CNAME de validation ACM et
# attend l'émission du certificat : apply en une passe.
#
# ID NU, sans le préfixe `/hostedzone/` que renvoie l'API : le provider stocke la
# forme nue dans l'état, donc la forme préfixée produit un diff permanent, et
# certaines ressources la rejettent carrément.
#
# Au go-live cette variable repasse à "" — les records de reactionpermis.fr et
# www.reactionpermis.fr existent déjà et les adopter rendrait un retour arrière
# dangereux (une erreur d'état supprimerait l'apex du domaine).
app_route53_zone_id = "Z0640180MSVICF0UZFEL"

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

# Mode pré-prod verrouillée. ⚠️ L'IP du poste change (FAI non fixe) : la
# re-vérifier à chaque session (`curl https://checkip.amazonaws.com`) sinon on se
# verrouille soi-même dehors. Relevée le 2026-08-25.
# Vider cette liste = site public : retire la condition source_ip des règles de
# forward ET supprime les deux règles 403 qui les doublaient (count à 0).
app_allowed_source_ips = ["88.138.235.45/32"]

# Branches autorisées à déployer sur cet environnement (trust policy OIDC). Doit
# rester aligné avec les triggers de deploy.yml : main et release/**. Un
# workflow_dispatch depuis une autre branche échouera à l'assume role — c'est
# voulu, la cible est la production.
github_deploy_branch_patterns = ["main", "release/*"]

# ─── App Laravel / ECS ────────────────────────────────────────────────────────
# Dimensionnement de production dès la pré-prod, volontairement : le go-live ne
# doit changer QUE les conditions de routage. Modifier en même temps la forme du
# calcul ajouterait un facteur de risque à l'instant le plus critique.
# 2 tasks = haute disponibilité, et aucun instant à zéro capacité pendant un
# déploiement.
app_image_tag      = "latest" # le workflow pousse <env>-<sha>-<ts> ET latest, puis force-new-deployment
app_cpu            = 1024
app_memory         = 2048
app_desired_count  = 2
app_container_port = 8080
log_retention_days = 90

app_env   = "production"
app_debug = false

app_extra_env = {
  # Verrou SEO : tant que le site est servi sous preprod.reactionpermis.fr, le
  # layout injecte <meta name="robots" content="noindex,nofollow">.
  # ⚠️ À PASSER À "false" au go-live, sinon reactionpermis.fr part en production
  # en noindex et disparaît de l'index Google.
  APP_NOINDEX = "true"
}

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
