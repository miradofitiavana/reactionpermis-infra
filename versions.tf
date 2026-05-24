# Versions Terraform + providers requis.
#
# AWS ~> 5.70 : on accepte 5.70.x → 5.x.x, mais pas 6.0 (breaking changes annoncés).
# random ~> 3.6 : pour les suffixes uniques de bucket + APP_KEY générée.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
