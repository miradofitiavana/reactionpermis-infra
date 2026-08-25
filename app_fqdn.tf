# Expose Laravel via un FQDN HTTPS (ex: dev.reactionpermis.fr).
#
# Pattern : pas de nouvel ALB - on greffe une listener rule host-based sur le
# 443 HTTPS de l'ALB partagé aaaep, avec un cert ACM attaché en SNI.
#
# Deux modes selon l'environnement :
#   - zone Route53 dans un AUTRE compte (cas du dev, dont reactionpermis.fr vit
#     côté prod) : app_route53_zone_id vide, records posés à la main.
#       1. `terraform apply` crée le cert ACM (status PENDING_VALIDATION)
#       2. `terraform output app_acm_validation_records`
#       3. créer ces CNAME dans la zone Route53 du compte prod
#       4. attendre ~5-15 min qu'ACM passe en ISSUED
#       5. créer un CNAME app_fqdn → DNS de l'ALB
#       6. test : https://<app_fqdn>/up doit répondre 200
#   - zone Route53 dans CE compte (cas de la prod) : app_route53_zone_id
#     renseigné, Terraform fait tout en une passe.

# Certificat existant, créé hors Terraform et possédé par la fondation du compte.
# Résolu par domaine : `reactionpermis.fr` sert déjà sur cet ALB, son certificat
# est donc déjà attaché au listener 443. Attention, un wildcard ne couvre qu'UN
# niveau : `*.reactionpermis.fr` vaut pour `preprod.reactionpermis.fr`, pas pour
# `x.y.reactionpermis.fr`. Vérifier les SAN avant de s'appuyer dessus.
data "aws_acm_certificate" "external" {
  count       = local.app_cert_external ? 1 : 0
  domain      = var.app_acm_certificate_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

# Cert ACM régional (eu-west-3) émis pour le FQDN app — seulement si aucun
# certificat existant n'a été désigné.
resource "aws_acm_certificate" "app" {
  count             = local.app_cert_managed ? 1 : 0
  domain_name       = var.app_fqdn
  validation_method = "DNS"

  # Les hôtes servis par la même règle doivent aussi être couverts, sinon l'ALB
  # présente un certificat invalide sur l'alias et le navigateur refuse avant
  # même d'atteindre l'application.
  subject_alternative_names = var.app_additional_hosts

  lifecycle {
    # Re-création du cert (ex: changement de domain_name) : crée avant de
    # détruire l'ancien pour éviter une coupure HTTPS.
    create_before_destroy = true
  }

  tags = {
    Purpose = "Laravel app FQDN"
  }
}

# ─── DNS piloté par Terraform (zone dans le même compte) ─────────────────────
# Ne s'active que si app_route53_zone_id est renseigné. Quand la zone vit dans un
# autre compte (cas du dev), ces trois ressources n'existent pas et on retombe sur
# la procédure manuelle décrite en tête de fichier.

# Records CNAME de validation ACM. for_each plutôt que count : ACM peut demander
# plusieurs records (un par domaine du cert), et une clé stable évite que l'ajout
# d'un domaine décale les index et recrée les records existants.
resource "aws_route53_record" "app_cert_validation" {
  for_each = local.app_dns_managed && local.app_cert_managed ? {
    for dvo in aws_acm_certificate.app[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id = var.app_route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  # Un cert recréé réémet les mêmes noms de records : sans ça, l'apply échoue sur
  # « record already exists » au lieu de le mettre à jour.
  allow_overwrite = true
}

# Bloque jusqu'à ce qu'ACM ait constaté la validation. Ne crée rien : c'est une
# barrière d'ordonnancement, elle rend l'attachement au listener possible en une
# seule passe au lieu des deux apply de la procédure manuelle.
resource "aws_acm_certificate_validation" "app" {
  count                   = local.app_dns_managed && local.app_cert_managed ? 1 : 0
  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for r in aws_route53_record.app_cert_validation : r.fqdn]
}

# Alias A vers l'ALB partagé. Alias et non CNAME : Route53 autorise l'alias à
# l'apex d'une zone, ce qu'un CNAME ne permet pas.
#
# PAS d'allow_overwrite ici, volontairement : les records de reactionpermis.fr et
# www.reactionpermis.fr existent déjà et pointent vers l'ALB. On veut qu'un apply
# qui les viserait échoue bruyamment plutôt qu'il détourne le trafic du site live
# sans prévenir. Au go-live, app_route53_zone_id est vidé et le DNS reste hors
# Terraform : la bascule se joue uniquement sur les règles de listener.
resource "aws_route53_record" "app_alias" {
  count   = local.app_dns_managed ? 1 : 0
  zone_id = var.app_route53_zone_id
  name    = var.app_fqdn
  type    = "A"

  alias {
    name                   = data.aws_lb.shared.dns_name
    zone_id                = data.aws_lb.shared.zone_id
    evaluate_target_health = false
  }
}

# Attache NOTRE cert au listener 443 de l'ALB partagé via SNI.
#
# Uniquement quand ce stack possède le certificat. Si on consomme celui de la
# fondation, l'attachement lui appartient : le déclarer ici ferait gérer la même
# ressource par deux états, et un destroy de notre côté détacherait le certificat
# qui sert reactionpermis.fr en production.
#
# Le cert doit être ISSUED sinon l'attach échoue sur un `UnsupportedCertificate`
# trompeur (le message parle de FQDN et de taille de clé, la vraie cause est
# l'état PENDING_VALIDATION). Avec le DNS géré, depends_on garantit l'ordre ;
# sans lui, il faut 2 apply encadrant la pose manuelle des records.
resource "aws_lb_listener_certificate" "app" {
  count           = local.app_cert_managed ? 1 : 0
  listener_arn    = var.shared_alb_listener_https_arn
  certificate_arn = aws_acm_certificate.app[0].arn

  depends_on = [aws_acm_certificate_validation.app]
}

# ─── Règles de listener ──────────────────────────────────────────────────────
#
# Mode pré-prod verrouillée : quand `app_allowed_source_ips` est non vide, un
# bloc condition `source_ip` s'ajoute aux règles de forward. Les conditions d'une
# MÊME règle ALB sont combinées en ET logique → seuls Host correct ET IP
# autorisée atteignent Laravel ; tout autre visiteur du même Host tombe sur la
# règle 403 qui suit. Ouvrir au public au go-live = vider la liste (une tfvar).

# 443 : Host = app_fqdn (+ alias) → forward au TG app.
resource "aws_lb_listener_rule" "app_https" {
  count        = local.enable_app_fqdn ? 1 : 0
  listener_arn = var.shared_alb_listener_https_arn
  priority     = var.app_listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    host_header {
      values = concat([var.app_fqdn], var.app_additional_hosts)
    }
  }

  # `dynamic` : bloc répété selon une collection. Ici 0 ou 1 occurrence — la
  # condition source_ip n'existe que si la liste d'IPs autorisées est non vide.
  dynamic "condition" {
    for_each = length(var.app_allowed_source_ips) > 0 ? [1] : []
    content {
      source_ip {
        values = var.app_allowed_source_ips
      }
    }
  }
}

# Barrière pré-prod sur le 443 : même Host mais IP NON autorisée → 403 explicite.
# Priorité juste après la règle forward (les règles ALB s'évaluent par priorité
# croissante, la première qui matche gagne). Sans cette règle, une requête non
# autorisée continuerait vers les règles suivantes de l'ALB partagé et pourrait
# être servie par le site aaaep par défaut — confus et indésirable.
resource "aws_lb_listener_rule" "app_https_deny" {
  count        = local.enable_app_fqdn && length(var.app_allowed_source_ips) > 0 ? 1 : 0
  listener_arn = var.shared_alb_listener_https_arn
  priority     = var.app_listener_rule_priority + 1

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Accès restreint."
      status_code  = "403"
    }
  }

  condition {
    host_header {
      values = concat([var.app_fqdn], var.app_additional_hosts)
    }
  }
}

# 80 : transmet à l'application, qui fait la montée en HTTPS (docker/nginx.conf
# lit X-Forwarded-Proto).
#
# Pourquoi PAS l'action `redirect` de l'ALB, qui était le réflexe et l'état
# précédent de ce fichier : sa cible n'accepte que des littéraux et les mots
# réservés #{host}/#{path}/#{query}, et le port doit y être explicite — omettre
# `port` conserve le port d'origine (80), le renseigner à 443 produit un
# `Location: https://hote:443/…`. On obtenait donc soit une cible en http, soit
# un port explicite dans l'URL, plus un second saut quand l'hôte demandé était
# l'apex (redirect vers https://apex:443, PUIS 301 de nginx vers www). Trois
# sauts pour http://reactionpermis.fr.
#
# En forwardant, nginx émet la redirection lui-même : un seul saut, sans port,
# directement vers l'hôte canonique.
#
# Conséquence de sécurité : le port 80 atteint maintenant la tâche. La condition
# source_ip est donc reproduite ici, et la règle deny ci-dessous la double — sans
# quoi le verrou par IP du 443 serait contournable en http.
resource "aws_lb_listener_rule" "app_http" {
  count        = local.enable_app_fqdn && var.shared_alb_listener_http_arn != "" ? 1 : 0
  listener_arn = var.shared_alb_listener_http_arn
  priority     = var.app_listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    host_header {
      values = concat([var.app_fqdn], var.app_additional_hosts)
    }
  }

  dynamic "condition" {
    for_each = length(var.app_allowed_source_ips) > 0 ? [1] : []
    content {
      source_ip {
        values = var.app_allowed_source_ips
      }
    }
  }
}

# Barrière pré-prod sur le 80, symétrique de celle du 443.
resource "aws_lb_listener_rule" "app_http_deny" {
  count        = local.enable_app_fqdn && var.shared_alb_listener_http_arn != "" && length(var.app_allowed_source_ips) > 0 ? 1 : 0
  listener_arn = var.shared_alb_listener_http_arn
  priority     = var.app_listener_rule_priority + 1

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Accès restreint."
      status_code  = "403"
    }
  }

  condition {
    host_header {
      values = concat([var.app_fqdn], var.app_additional_hosts)
    }
  }
}

# La règle change de rôle, donc de nom. Sans ce bloc, Terraform détruirait puis
# recréerait la règle : entre les deux, le port 80 de dev.reactionpermis.fr
# tomberait sur l'action par défaut de l'ALB, donc sur le site aaaep.
moved {
  from = aws_lb_listener_rule.app_http_redirect
  to   = aws_lb_listener_rule.app_http
}
