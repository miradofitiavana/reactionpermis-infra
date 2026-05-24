# ALB mutualisé — Target Group Laravel + data source ALB.
#
# On NE crée PAS d'ALB : on réutilise `aaaep-site-web-alb`.
# Le routing vers Laravel se fait via une listener rule host-based sur le
# listener 443 HTTPS de l'ALB partagé — cf app_fqdn.tf.

# Expose le DNS de l'ALB partagé (utilisé en outputs + CNAME Route53 prod).
data "aws_lb" "shared" {
  arn = var.shared_alb_arn
}

# Target Group Laravel : ECS y enregistre les IPs des tasks automatiquement.
# Health check sur `/up` (route fournie par Laravel 11+ pour les probes).
resource "aws_lb_target_group" "app" {
  name        = "${local.name_prefix}-app-tg"
  port        = var.app_container_port
  protocol    = "HTTP"
  target_type = "ip" # awsvpc + Fargate = IP-based targets
  vpc_id      = var.vpc_id

  # Drain rapide : si une task se termine, ALB la déregistre en 30s au lieu de 5min.
  deregistration_delay = 30

  health_check {
    path                = "/up"
    matcher             = "200-299"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    # Si nginx renvoie autre chose que JSON sur /up, ALB regarde quand même
    # le code HTTP. Laravel `/up` rend une vue HTML mais HTTP 200.
  }

  # Sticky sessions désactivées : on a EFS pour le storage partagé, donc tout
  # task peut servir n'importe quelle requête.
  stickiness {
    type    = "lb_cookie"
    enabled = false
  }
}
