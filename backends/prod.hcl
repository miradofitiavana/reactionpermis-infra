# Bucket distinct de celui du dev : le state d'un compte doit rester dans le
# compte qu'il décrit. `reactionpermis-tfstate` appartient au compte dev
# (211125435907) ; l'utiliser depuis la prod donnerait au compte dev la lecture
# de la description de l'infrastructure de production, et un head-bucket depuis
# la prod répond de toute façon 403.
#
# Création one-time dans le compte prod (381492212876) :
#   aws s3api create-bucket --bucket reactionpermis-tfstate-prod --region eu-west-3 \
#     --create-bucket-configuration LocationConstraint=eu-west-3
#   aws s3api put-bucket-versioning --bucket reactionpermis-tfstate-prod \
#     --versioning-configuration Status=Enabled
#   aws s3api put-bucket-encryption --bucket reactionpermis-tfstate-prod \
#     --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
#   aws s3api put-public-access-block --bucket reactionpermis-tfstate-prod \
#     --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
bucket       = "reactionpermis-tfstate-prod"
key          = "prod/terraform.tfstate"
region       = "eu-west-3"
use_lockfile = true
encrypt      = true
