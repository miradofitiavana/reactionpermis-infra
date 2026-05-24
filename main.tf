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
}

data "aws_caller_identity" "current" {}
