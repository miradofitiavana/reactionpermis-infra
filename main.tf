# Provider AWS + locals partagés entre tous les fichiers.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Stack       = "reactionpermis-2026"
    }
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  is_prod     = var.environment == "prod"

  enable_app_fqdn = var.app_fqdn != "" && var.shared_alb_listener_https_arn != ""

  # DNS piloté par Terraform : possible seulement si la zone est dans ce compte.
  # Sinon (dev, dont la zone reactionpermis.fr vit côté prod) les records se
  # posent à la main.
  app_dns_managed = local.enable_app_fqdn && var.app_route53_zone_id != ""

  # Certificat : soit on consomme celui de la fondation, soit on émet le nôtre.
  # Consommer implique de ne PAS gérer l'attachement au listener — il appartient
  # à qui possède le certificat, et un destroy de notre côté couperait le TLS des
  # autres hosts qui s'appuient dessus (dont reactionpermis.fr en production).
  app_cert_external = local.enable_app_fqdn && var.app_acm_certificate_domain != ""
  app_cert_managed  = local.enable_app_fqdn && !local.app_cert_external
}

data "aws_caller_identity" "current" {}
