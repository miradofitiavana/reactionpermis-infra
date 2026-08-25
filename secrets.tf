# Secrets Manager : un secret JSON par environnement, consommé par la task ECS.
#
# Secrets stockés :
#   - APP_KEY        : clé symétrique Laravel (cookies, sessions, encrypted casts)
#   - DB_PASSWORD    : mot de passe MySQL Laravel
#   - LYRA_USERNAME  : identifiant boutique Lyra (paiement du test psychotechnique)
#   - LYRA_PWD       : mot de passe boutique Lyra
#
# Terraform crée le CONTENEUR mais jamais les valeurs : tout ce qu'il manipule
# atterrit en clair dans le tfstate, y compris le résultat d'un `data` source —
# lire le secret depuis Terraform ne changerait donc rien au problème. Les vraies
# valeurs sont poussées hors Terraform :
#
#   $j = @{ APP_KEY='base64:...'; DB_PASSWORD='...'; LYRA_USERNAME='...'; LYRA_PWD='...' } | ConvertTo-Json -Compress
#   aws secretsmanager put-secret-value --secret-id reactionpermis-prod-app --secret-string $j
#
# put-secret-value remplace le JSON ENTIER : pousser une seule clé efface les
# autres et coupe l'accès MySQL de l'application. Toujours relire le secret,
# modifier la clé voulue, repousser le tout.
#
# APP_KEY se génère avec `php artisan key:generate --show` (format `base64:<32o>`).
# La perdre rend illisibles cookies chiffrés et casts encrypted : la conserver.
#
# Rappel Lyra : LYRA_PWD sert AUSSI, côté API organisme, à vérifier la signature
# de l'IPN. Le faire tourner ici sans le changer là-bas casse la confirmation des
# paiements (client débité, réservation jamais validée).
#
# Pas de rotation auto. Après un put-secret-value, faire un
# `aws ecs update-service --force-new-deployment` pour que les tasks repick.

resource "aws_secretsmanager_secret" "app" {
  name = "${local.name_prefix}-app"

  # Pas de recovery window en dev : permet de destroy/recreate rapidement.
  # En prod, 7 jours de rétention pour éviter une suppression accidentelle.
  recovery_window_in_days = local.is_prod ? 7 : 0
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id

  # Les 4 clés doivent exister dès la création : ecs.tf les référence une par une
  # (`valueFrom = <arn>:<KEY>::`) et ECS refuse de démarrer la task si l'une
  # manque (ResourceInitializationError, conteneur jamais lancé). D'où des
  # placeholders plutôt qu'un secret vide - une task qui boote avec ces valeurs
  # échouera à se connecter à MySQL, ce qui est le symptôme voulu si on oublie
  # l'injection.
  secret_string = jsonencode({
    APP_KEY     = "A_INJECTER"
    DB_PASSWORD = "A_INJECTER"
    # Contrairement aux deux précédentes, un placeholder ici ne casse pas le
    # démarrage : le tunnel affiche « paiement non configuré » au lieu d'encaisser.
    LYRA_USERNAME = "A_INJECTER"
    LYRA_PWD      = "A_INJECTER"
  })

  lifecycle {
    # Sans ça, chaque apply réécrirait les vraies valeurs par les placeholders.
    #
    # ⚠️ Corollaire sur un secret DÉJÀ existant (cas du dev) : ignore_changes
    # empêche aussi Terraform d'y AJOUTER les clés LYRA_* nouvellement
    # référencées par ecs.tf. Les pousser à la main avant l'apply, sinon la task
    # échoue en ResourceInitializationError.
    ignore_changes = [secret_string]
  }
}
