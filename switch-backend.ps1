# Bascule le backend Terraform entre dev et prod.
#
# Pourquoi un script pour une seule commande : coller
# `terraform init -reconfigure -backend-config=backends/<env>.hcl` dans la console
# de ce poste insere regulierement un octet 0x16 invisible, que Terraform recoit
# comme un argument positionnel et rejette avec « Too many command line arguments ».
# Taper `.\switch-backend.ps1 dev` evite le collage.
#
# -reconfigure : on CHANGE de backend sans migrer l'etat. Sans lui, Terraform
# proposerait de copier le state de l'environnement courant vers l'autre, ce qui
# ecraserait une infrastructure avec la description d'une autre.
#
# Usage :
#   .\switch-backend.ps1 dev
#   .\switch-backend.ps1 prod

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'prod')]
    [string]$Environment
)

$ErrorActionPreference = 'Stop'

$backend = "backends/$Environment.hcl"

if (-not (Test-Path $backend)) {
    Write-Error "Fichier de backend introuvable : $backend"
    exit 1
}

Write-Host "Bascule du backend Terraform vers '$Environment' ($backend)" -ForegroundColor Cyan
Write-Host "Rappel : le compte AWS doit correspondre. dev = 211125435907, prod = 381492212876." -ForegroundColor DarkGray

terraform init -reconfigure "-backend-config=$backend"

if ($LASTEXITCODE -ne 0) {
    Write-Error "terraform init a echoue (code $LASTEXITCODE)."
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "[OK] Backend actif : $Environment" -ForegroundColor Green
Write-Host "Plan  : terraform plan -out=tfplan -var-file=envs/$Environment.tfvars" -ForegroundColor DarkGray
Write-Host "Apply : terraform apply tfplan" -ForegroundColor DarkGray
