# Remote state (backend S3 + lock natif S3).
#
# Pourquoi remote state plutôt que local ?
#   - terraform.tfstate contient secrets, ARNs, IDs - sensible
#   - lock S3 (use_lockfile, TF ≥ 1.10) empêche deux `apply` simultanés
#   - permet à plusieurs personnes / GitHub Actions de partager le même state
#
# Setup one-time (hors Terraform) :
#   aws s3api create-bucket --bucket reactionpermis-tfstate --region eu-west-3 \
#     --create-bucket-configuration LocationConstraint=eu-west-3
#   aws s3api put-bucket-versioning --bucket reactionpermis-tfstate \
#     --versioning-configuration Status=Enabled
#   aws s3api put-bucket-encryption --bucket reactionpermis-tfstate \
#     --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
#
# (Pas de DynamoDB requis - le lock est géré nativement par S3 via use_lockfile.)
#
# Puis : terraform init -reconfigure -backend-config=backends/dev.hcl

terraform {
  backend "s3" {
    # Valeurs fournies via `-backend-config=backends/<env>.hcl` (1 state par env).
    # Cf. backends/dev.hcl : bucket, key, region, use_lockfile = true, encrypt.
  }
}
