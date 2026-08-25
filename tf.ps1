# Enveloppe Terraform par environnement, pour ne plus coller d'arguments longs.
#
# Deux problemes recurrents sur ce poste, tous deux resolus en tapant une commande
# courte plutot qu'en collant :
#   - le collage console insere un octet 0x16 invisible, que Terraform recoit comme
#     un argument positionnel : « Too many command line arguments ».
#   - grouper plusieurs flags dans une seule paire de guillemets les transforme en
#     un unique argument : `-var-file` est alors ignore et Terraform reclame chaque
#     variable en invite interactive, dont l'interruption laisse un lock orphelin.
#
# Usage :
#   .\tf.ps1 dev plan
#   .\tf.ps1 dev apply
#   .\tf.ps1 dev unlock 281c8418-10c5-3cac-120b-804103377b7e
#
# Le backend doit deja pointer sur le bon environnement : .\switch-backend.ps1 dev

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [ValidateSet('plan', 'apply', 'unlock')]
    [string]$Action,

    # Identifiant du lock, uniquement pour l'action unlock.
    [string]$LockId
)

$ErrorActionPreference = 'Stop'

$varFile = "envs/$Environment.tfvars"
$planFile = "tfplan.$Environment"

if (-not (Test-Path $varFile)) {
    Write-Error "Fichier de variables introuvable : $varFile"
    exit 1
}

switch ($Action) {
    'plan' {
        # -out : on fige le plan pour que l'apply applique EXACTEMENT ce qui a ete
        # relu, et n'ait aucune question a poser. Une invite de confirmation sans
        # terminal interactif echoue en EOF et laisse un lock orphelin.
        terraform plan "-out=$planFile" "-var-file=$varFile"
    }
    'apply' {
        if (-not (Test-Path $planFile)) {
            Write-Error "Aucun plan enregistre ($planFile). Lancer d'abord : .\tf.ps1 $Environment plan"
            exit 1
        }
        terraform apply $planFile
        if ($LASTEXITCODE -eq 0) {
            Remove-Item $planFile -ErrorAction SilentlyContinue
            Write-Host "[OK] Applique, plan consomme et supprime." -ForegroundColor Green
        }
    }
    'unlock' {
        if ([string]::IsNullOrWhiteSpace($LockId)) {
            Write-Error "Identifiant de lock manquant. Il figure dans le message d'erreur, ligne « ID: »."
            exit 1
        }
        # -force : saute la confirmation, qui est precisement ce qui echoue quand
        # l'entree standard n'est pas interactive. N'est sur que si aucun autre
        # apply ne tourne reellement - verifier le champ « Who » du message.
        terraform force-unlock -force $LockId
    }
}

exit $LASTEXITCODE
