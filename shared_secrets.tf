# Secrets fournisseur partagés avec d'autres applications (dépôt aaaep-shared-infra).
#
# La boutique Lyra Reaction-Permis sert à deux applications : ce site (création du paiement)
# et l'API organisme (vérification du kr-hash de l'IPN avec le même mot de passe). Ses
# identifiants vivent donc dans un secret unique, shared/<env>/lyra-rp, géré par
# aaaep-shared-infra, et non plus dans le secret applicatif de cette stack. Une rotation se
# fait là-bas (scripts/secrets.ps1 puis scripts/rotate.ps1), en une fois pour les deux
# applications : c'est ce qui évite le « client débité, réservation jamais confirmée ».
#
# Les data sources ne lisent que des métadonnées (nom, ARN), jamais la valeur : rien de
# sensible n'arrive dans le state.
#
# var.shared_secrets_env = null (défaut) : aucun secret partagé, la task garde LYRA_USERNAME
# et LYRA_PWD du secret applicatif et LYRA_PK de var.lyra_public_key. C'est le cas de la prod
# tant que aaaep-shared-infra n'y est pas appliqué (les data sources échoueraient au plan).

locals {
  # Variable d'environnement lue par Laravel (config/services.php, bloc lyra) => secret partagé
  # et clé JSON dans ce secret. Les noms de gauche sont ceux de l'application, ceux de droite
  # les clés normalisées du catalogue de aaaep-shared-infra (secrets.catalog.json).
  # LYRA_PK n'est pas sensible (le navigateur la reçoit), mais elle désigne la boutique : la
  # lire au même endroit que l'identifiant garantit qu'elles restent cohérentes.
  # BREVO_API_KEY : le compte Brevo est celui d'AAAEP, la clé vit dans brevo-aaaep (une
  # seule copie, une rotation en un seul endroit). Rien d'autre à brancher : l'application
  # n'utilise ni Trustpilot, ni Alma.
  #
  # Chaque entrée porte son environnement : Lyra suit shared_secrets_env, Brevo suit
  # shared_brevo_env (ou, à défaut, shared_secrets_env). La prod peut ainsi lire la clé Brevo
  # dans le secret partagé sans toucher à l'origine des identifiants de paiement.
  brevo_shared_env = var.shared_brevo_env != null ? var.shared_brevo_env : var.shared_secrets_env

  shared_secret_vars = merge(
    var.shared_secrets_env == null ? {} : {
      LYRA_USERNAME = { env = var.shared_secrets_env, secret = "lyra-rp", key = "LYRA_USERNAME" }
      LYRA_PWD      = { env = var.shared_secrets_env, secret = "lyra-rp", key = "LYRA_PASSWORD" }
      LYRA_PK       = { env = var.shared_secrets_env, secret = "lyra-rp", key = "LYRA_PUBLIC_KEY" }
    },
    local.brevo_shared_env == null ? {} : {
      BREVO_API_KEY = { env = local.brevo_shared_env, secret = "brevo-aaaep", key = "BREVO_API_KEY" }
    },
  )

  # Un data source et une policy par secret, pas par variable : nom du secret => environnement.
  shared_secret_envs = {
    for name in toset([for v in values(local.shared_secret_vars) : v.secret]) :
    name => one(distinct([for v in values(local.shared_secret_vars) : v.env if v.secret == name]))
  }

  # Entrées `secrets` de la task, triées pour un plan stable. valueFrom = "<arn>:<CLE>::" :
  # ARN complet, clé JSON, puis version-stage et version-id laissés vides (version courante).
  shared_secret_task_entries = [
    for name in sort(keys(local.shared_secret_vars)) : {
      name      = name
      valueFrom = "${data.aws_secretsmanager_secret.shared[local.shared_secret_vars[name].secret].arn}:${local.shared_secret_vars[name].key}::"
    }
  ]

  # Une variable aussi posée dans app_extra_env apparaîtrait deux fois dans la task (en clair
  # et en secret), et ECS ne dit pas laquelle gagne. Vérifié par une precondition (ecs.tf).
  shared_secret_overlap = sort(setintersection(toset(keys(local.shared_secret_vars)), toset(keys(var.app_extra_env))))
}

# Retrouve le secret par son nom : l'ARN porte un suffixe aléatoire posé par AWS, impossible à
# reconstruire. Échoue au plan si aaaep-shared-infra n'est pas appliqué dans ce compte.
data "aws_secretsmanager_secret" "shared" {
  for_each = local.shared_secret_envs
  name     = "shared/${each.value}/${each.key}"
}

# Policy de lecture seule créée par aaaep-shared-infra pour ce secret (GetSecretValue sur ce
# seul ARN), retrouvée par son nom plutôt que réécrite ici : cette stack ne peut lire que
# lyra-rp et brevo-aaaep, pas les identifiants des autres marques.
data "aws_iam_policy" "shared_read" {
  for_each = local.shared_secret_envs
  name     = "shared-${each.value}-read-${each.key}"
}

# Sur le rôle d'EXÉCUTION : c'est lui qu'ECS utilise pour injecter les secrets au démarrage
# d'une task. Le rôle de task (celui de Laravel) n'en a pas besoin.
resource "aws_iam_role_policy_attachment" "task_execution_shared" {
  for_each   = local.shared_secret_envs
  role       = aws_iam_role.task_execution.name
  policy_arn = data.aws_iam_policy.shared_read[each.key].arn
}
