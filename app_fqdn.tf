# Expose Laravel via un FQDN HTTPS (ex: dev.reactionpermis.fr).
#
# Pattern : pas de nouvel ALB - on greffe une listener rule host-based sur le
# 443 HTTPS de l'ALB partagé aaaep, avec un cert ACM attaché en SNI.
#
# Prérequis manuels (car Route53 reactionpermis.fr vit dans le compte prod
# alors qu'on déploie dans le compte dev) :
#   1. `terraform apply` crée le cert ACM (status PENDING_VALIDATION)
#   2. Récupère les records de validation : `terraform output app_acm_validation_records`
#   3. Dans la console Route53 du compte prod, crée ces CNAME sur reactionpermis.fr
#   4. Attends ~5-15 min que ACM passe en ISSUED
#   5. Dans la même zone Route53 prod, crée un CNAME app_fqdn → DNS de l'ALB
#   6. Test : https://<app_fqdn>/up doit répondre 200

# Cert ACM régional (eu-west-3) pour le FQDN app.
resource "aws_acm_certificate" "app" {
  count             = local.enable_app_fqdn ? 1 : 0
  domain_name       = var.app_fqdn
  validation_method = "DNS"

  lifecycle {
    # Re-création du cert (ex: changement de domain_name) : crée avant de
    # détruire l'ancien pour éviter une coupure HTTPS.
    create_before_destroy = true
  }

  tags = {
    Purpose = "Laravel app FQDN"
  }
}

# Attache le cert au listener 443 de l'ALB partagé via SNI.
# Le cert doit être ISSUED sinon l'attach échoue → 2 apply si besoin (1er pour
# créer le cert + récupérer les records, 2e après validation DNS).
resource "aws_lb_listener_certificate" "app" {
  count           = local.enable_app_fqdn ? 1 : 0
  listener_arn    = var.shared_alb_listener_https_arn
  certificate_arn = aws_acm_certificate.app[0].arn
}

# Listener rule sur 443 : Host = app_fqdn → forward au TG app.
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
      values = [var.app_fqdn]
    }
  }
}

# Listener rule sur 80 : redirige HTTP → HTTPS pour app_fqdn (optionnel).
resource "aws_lb_listener_rule" "app_http_redirect" {
  count        = local.enable_app_fqdn && var.shared_alb_listener_http_arn != "" ? 1 : 0
  listener_arn = var.shared_alb_listener_http_arn
  priority     = var.app_listener_rule_priority

  action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }

  condition {
    host_header {
      values = [var.app_fqdn]
    }
  }
}
