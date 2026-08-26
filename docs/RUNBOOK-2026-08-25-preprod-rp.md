# Runbook — Pré-prod verrouillée de reactionpermis-2026

Mise en place de l'infrastructure de **production définitive** dans le compte
`381492212876`, exposée sur `preprod.reactionpermis.fr` et restreinte à l'IP du
poste, contre l'**Aurora de production** `aaaep-db-mysql-v1-cluster`.

Le site public `reactionpermis.fr` n'est **pas touché** : il continue d'être servi
par la règle de listener ALB historique (priorité 60), qui gagne sur la nôtre
(priorité 200) tant qu'elle existe. Le go-live fait l'objet d'un second runbook.

Modèle repris de `cntp-2026` (go-live du 2026-08-13), à deux différences près :
la règle du port 80 porte ici aussi le verrou par IP, et la clé publique Lyra
n'est pas inlinée au build (elle est lue à l'exécution depuis `LYRA_PK`), donc
Terraform la contrôle entièrement.

---

## 0. Prérequis et relevés — à faire en premier

### 0.1 Credentials AWS

Les credentials du poste étaient expirés au moment de la rédaction
(`ExpiredToken` sur `default` et `aaaep-prod`). Rien de ce qui suit ne marche
avant de les rafraîchir.

```powershell
aws sts get-caller-identity --profile aaaep-prod
# Attendu : "Account": "381492212876"
```

Tout le runbook suppose `$env:AWS_PROFILE = 'aaaep-prod'` ou `--profile aaaep-prod`
sur chaque commande. **Se tromper de compte est le principal risque de cette
opération** : le dev porte un ALB et un cluster Aurora du même nom.

### 0.2 Bucket de state prod

`backends/prod.hcl` pointe sur `reactionpermis-tfstate-prod`, et non sur
`reactionpermis-tfstate` qui appartient au compte dev (même piège que sur CNTP :
`head-bucket` répond 403 depuis la prod et le bucket est absent de `list-buckets`).

**✅ Créé le 2026-08-25** — il n'existait pas. Versioning, chiffrement AES256 et
blocage d'accès public posés dans la foulée. Le versioning n'est pas décoratif :
sans lui, un tfstate écrasé ou corrompu n'est pas récupérable.

```powershell
aws s3api head-bucket --bucket reactionpermis-tfstate-prod
# Si 404 :
aws s3api create-bucket --bucket reactionpermis-tfstate-prod --region eu-west-3 `
  --create-bucket-configuration LocationConstraint=eu-west-3
aws s3api put-bucket-versioning --bucket reactionpermis-tfstate-prod `
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket reactionpermis-tfstate-prod `
  --server-side-encryption-configuration '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}'
aws s3api put-public-access-block --bucket reactionpermis-tfstate-prod `
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### 0.3 Zone Route53 de reactionpermis.fr

```powershell
aws route53 list-hosted-zones-by-name --dns-name reactionpermis.fr --query "HostedZones[].{id:Id,name:Name,records:ResourceRecordSetCount}" --output table
```

**✅ Relevé le 2026-08-25** : `Z0640180MSVICF0UZFEL`, 20 records. Reporté dans
`app_route53_zone_id`.

⚠️ **Sans le préfixe `/hostedzone/`** que renvoie l'API : le provider stocke la
forme nue dans l'état, donc la forme préfixée produit un diff permanent.

### 0.4 Certificat ACM

`reactionpermis.fr` est déjà servi par cet ALB, son certificat y est donc déjà
attaché. Relever ses SAN :

```powershell
$arn = (aws acm list-certificates --region eu-west-3 `
  --query "CertificateSummaryList[?DomainName=='reactionpermis.fr'].CertificateArn" --output text)
aws acm describe-certificate --certificate-arn $arn --region eu-west-3 `
  --query "Certificate.{domain:DomainName,san:SubjectAlternativeNames,status:Status}"
```

**✅ Tranché le 2026-08-25.** Il n'existe qu'un certificat pour ce domaine,
`arn:…:certificate/a015d790-a196-4d2b-82ca-739d469d5ea0`, `ISSUED`, SAN
`[reactionpermis.fr, *.reactionpermis.fr, www.reactionpermis.fr]`, déjà attaché à
`aaaep-site-web-alb`. Le wildcard couvre `preprod.reactionpermis.fr`.

→ `app_acm_certificate_domain = "reactionpermis.fr"` **dès la pré-prod**, et cette
variable ne changera pas au go-live. Le stack consomme le certificat sans le
posséder : aucune émission, aucun `aws_lb_listener_certificate` de notre côté, et
donc aucun risque qu'un destroy chez nous détache le certificat du site de
production.

Conséquence sur le plan Terraform : ni `aws_acm_certificate.app`, ni
`aws_acm_certificate_validation.app`, ni `aws_route53_record.app_cert_validation`
n'apparaîtront. Seul l'alias `preprod.reactionpermis.fr` sera créé dans la zone.

### 0.5 Priorités de listener libres

Le bloc 200-209 est réservé à `reactionpermis-2026` dans le registre de
propriété. Ce stack prend **200** (forward) et **201** (403 du verrou), sur les
DEUX listeners.

**✅ Relevé le 2026-08-25 — 200 et 201 libres sur les deux.**

- Listener 443, priorités occupées : `1, 5, 9, 10, 20, 30, 40, 50, 51, 60, 80, 89,
  90, 100, 110`. La 70 a disparu : c'est celle qu'a supprimée le go-live cntp.
- Listener 80, priorités occupées : `1, 9, 110`. **Aucune règle n'y couvre
  `reactionpermis.fr`** : le `301` qu'on observe aujourd'hui sur
  `http://reactionpermis.fr` vient donc de l'action par défaut du listener, pas
  d'une règle. Conséquence au go-live : notre règle 200 prendra le relais et la
  redirection sera émise par nginx, ce qui est plus explicite — mais c'est un
  changement de chemin, à re-tester à ce moment-là.

Commandes de re-vérification (le `[]` après `sort_by` est nécessaire : sans lui
le multiselect s'applique à la liste et tout ressort à `None`) :

```powershell
$L443 = "arn:aws:elasticloadbalancing:eu-west-3:381492212876:listener/app/aaaep-site-web-alb/da203a6f6728345c/e4bbf9f610ffb951"
$L80  = "arn:aws:elasticloadbalancing:eu-west-3:381492212876:listener/app/aaaep-site-web-alb/da203a6f6728345c/1391cfd4ea9deb2b"
aws elbv2 describe-rules --listener-arn $L443 --query "sort_by(Rules[?Priority!='default'],&Priority)[].{p:Priority,hosts:Conditions[0].Values,action:Actions[0].Type}" --output table
aws elbv2 describe-rules --listener-arn $L80  --query "sort_by(Rules[?Priority!='default'],&Priority)[].{p:Priority,hosts:Conditions[0].Values,action:Actions[0].Type}" --output table
```

### 0.6 Conserver la règle du site actuel

C'est **la** ligne à sauvegarder : elle n'est dans aucun état Terraform, et c'est
elle qu'il faudra recréer en cas de retour arrière au go-live.

```powershell
aws elbv2 describe-rules --listener-arn $L443 `
  --query "Rules[?Priority=='60'].{arn:RuleArn,conditions:Conditions,actions:Actions}" --output json `
  | Tee-Object -FilePath .\regle-alb-60-reactionpermis.json
```

Garder ce fichier hors du dépôt et le relire avant le go-live.

### 0.7 Journal de migrations

`config/database.php` a été corrigé pour utiliser `rp2026_migrations` au lieu du
nom générique `migrations` : sur une base mutualisée entre cinq applications, un
journal nommé `migrations` est un nom commun qu'une autre application peut déjà
occuper, et deux applications qui le partagent se lisent mutuellement.

```sql
SELECT table_name FROM information_schema.tables
 WHERE table_schema = 'aaaep_aaaeporganisme'
   AND table_name IN ('migrations', 'rp2026_migrations', 'cntp2026_migrations');
```

**✅ Vérifié sur la prod le 2026-08-25 — le risque était réel** : `migrations` et
`cntp2026_migrations` existent, `rp2026_migrations` non. La table `migrations`
générique appartient donc à une autre application. Sans la correction de
`config/database.php`, rp2026 aurait lu et écrit le journal de cette
application-là.

Sur la **prod**, `rp2026_migrations` sera créée par le premier `php artisan
migrate` : rien à faire.

Sur le **dev**, les 35 migrations ont déjà été jouées et enregistrées sous
l'ancien nom. Après ce changement de configuration, Laravel ne les verra plus et
voudra tout rejouer — les seeds de contenu échoueraient sur des doublons. Avant
la prochaine migration en dev, rejouer la même requête **sur le cluster dev** puis
identifier à qui appartient sa table `migrations` :

```sql
SELECT id, batch, migration FROM migrations ORDER BY id DESC LIMIT 20;
```

- **Que des migrations rp2026** → recopier le journal (à faire jouer par l'admin) :

  ```sql
  CREATE TABLE rp2026_migrations LIKE migrations;
  INSERT INTO rp2026_migrations SELECT * FROM migrations;
  -- l'ancienne table n'est pas supprimée : la laisser tant qu'on n'a pas confirmé
  -- qu'aucune autre application ne la lit.
  ```

- **Mélange de plusieurs applications** → ne recopier que nos lignes
  (`WHERE migration LIKE '2026\_0%'` ne suffit pas, comparer avec le contenu de
  `database/migrations/`), et surtout ne rien supprimer.

---

## 1. Base de données

### 1.1 User MySQL dédié

Jouer `docs/2026-08-25-user-mysql-rp2026.sql` avec le user admin, contre le
cluster de **production**. Générer un mot de passe aléatoire et ne le coller que
dans Secrets Manager (§2).

Le fichier crée `rp2026'@'10.0.%'` plafonné à 80 connexions (2 tasks × 16 workers
php-fpm, ×2 pendant un rollout = 64 au pic), **sans aucun droit DDL**.

### 1.2 Migrations

Les 35 migrations créent les 13 tables `rp2026_*` **et seedent tout le contenu du
site** (menus, home, pages CMS, guides, hub situations, pages statiques legacy,
metas SEO importées de `sitev3_pages`). Il n'y a donc pas d'export de contenu à
faire depuis le dev — sauf pour ce qui aurait été saisi à la main dans le Filament
du dev après les seeds (articles, images uploadées) : ça, ça ne suivra pas.

À jouer depuis le poste avec le **user admin**, jamais depuis le conteneur (qui
n'a pas les droits, par conception) :

```powershell
# .env local pointé sur le cluster PROD, avec le user admin
php artisan migrate --force
php artisan migrate:status   # 35 lignes "Ran"
```

Vérifier ensuite que l'import SEO a bien trouvé sa source :

```sql
SELECT COUNT(*) FROM rp2026_seo_metas;   -- doit être > 0
SELECT COUNT(*) FROM rp2026_pages;
```

Un `rp2026_seo_metas` vide signifie que `sitev3_pages` est absente ou vide sur ce
cluster : le site fonctionnerait, mais sans aucune meta SEO importée.

---

## 2. Secrets Manager

Terraform crée le secret `reactionpermis-prod-app` avec 4 placeholders
`A_INJECTER` et `ignore_changes = [secret_string]` : les vraies valeurs n'entrent
jamais dans le tfstate. **Cette étape se fait donc APRÈS le premier apply** (le
secret doit exister), mais **AVANT que les tasks ne démarrent utilement**.

Ordre pratique : lancer l'apply (§3), puis injecter, puis forcer un redéploiement.

Passer par un **fichier** et non par `--secret-string $j` : le quoting de la
console mange les accolades et les guillemets, et on pousse alors une chaîne qui
n'est pas un objet JSON. C'est arrivé au premier essai le 2026-08-25 — ECS
échouait en `ResourceInitializationError: unable to retrieve secret from asm:
invalid character 'L' looking for beginning of object key string`, autrement dit
le parseur a trouvé une accolade puis une clé sans guillemets. Aucune task ne peut
démarrer dans cet état : ECS résout les `valueFrom` avant même de tirer l'image.

```powershell
$j = [ordered]@{
    APP_KEY       = 'base64:...'   # php artisan key:generate --show
    DB_PASSWORD   = '...'          # celui du user rp2026 créé au §1.1
    LYRA_USERNAME = '...'          # boutique Réaction Permis, clés de PRODUCTION
    LYRA_PWD      = '...'
} | ConvertTo-Json -Compress

# UTF8Encoding($false) = sans BOM. `Out-File -Encoding utf8` en PowerShell 5.1 en
# ajoute un, et le parseur JSON d'AWS le rejette.
[System.IO.File]::WriteAllText("$PWD\secret.json", $j, (New-Object System.Text.UTF8Encoding($false)))
aws secretsmanager put-secret-value --secret-id reactionpermis-prod-app --secret-string file://secret.json
Remove-Item secret.json

aws ecs update-service --cluster reactionpermis-prod-cluster --service reactionpermis-prod-app --force-new-deployment
```

Vérifier la forme sans afficher les valeurs — la commande naïve
(`get-secret-value | ConvertFrom-Json`) **imprime le secret en clair dans la
console** si le JSON est invalide, puisque l'erreur cite le contenu reçu :

```powershell
aws secretsmanager get-secret-value --secret-id reactionpermis-prod-app --query SecretString --output text | ConvertFrom-Json | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
```

Attendu : les 4 noms de clés, rien d'autre.

Trois pièges :

- `put-secret-value` remplace le JSON **entier**. Pousser une seule clé efface les
  autres et coupe l'accès MySQL. Toujours relire, modifier, repousser le tout.
- `LYRA_PWD` doit être **identique** à `WEB_API_REACTION_LYRA_PWD` côté API
  organisme : c'est avec lui que l'IPN vérifie la signature `kr-hash` du retour de
  paiement. Deux valeurs différentes = client débité, réservation jamais confirmée.
- `lyra_public_key` dans `envs/prod.tfvars` doit désigner **la même boutique** que
  `LYRA_USERNAME`, sinon PayZen refuse le formToken. Contrairement à CNTP, elle
  n'est pas inlinée au build : la corriger et refaire un apply suffit.

⚠️ Avec de vraies credentials de production, un paiement lancé depuis la pré-prod
est un **vrai débit** et crée une vraie ligne dans `organisme_reservations` de la
base de production. Tant qu'on ne veut pas encaisser, laisser `LYRA_USERNAME` et
`LYRA_PWD` sur `A_INJECTER` : le tunnel affiche « paiement non configuré » au lieu
de planter.

---

## 3. Terraform

### 3.1 Renseigner les valeurs relevées au §0

Dans `envs/prod.tfvars` :

| Variable | Valeur |
|---|---|
| `app_route53_zone_id` | ID relevé au §0.3, sans `/hostedzone/` |
| `app_acm_certificate_domain` | `""` ou `"reactionpermis.fr"` selon §0.4 |
| `app_allowed_source_ips` | IP publique du poste **du jour** |
| `lyra_public_key` | clé publique de production de la boutique |

L'IP du poste change (FAI non fixe) : la re-vérifier à **chaque** session, sinon
on se verrouille soi-même dehors.

```powershell
curl.exe -s https://checkip.amazonaws.com
```

### 3.2 Appliquer

```powershell
cd D:\reaction-permis\reactionpermis-aws
.\switch-backend.ps1 prod
.\tf.ps1 prod plan
.\tf.ps1 prod apply
```

Les deux scripts existent pour éviter deux pièges de ce poste : le collage console
insère un octet `0x16` invisible que Terraform rejette en « Too many command line
arguments », et un `apply` interrompu sur sa question de confirmation laisse un
lock S3 orphelin (`.\tf.ps1 prod unlock <id>` pour le lever). `plan -out` puis
`apply <plan>` ne pose aucune question.

Attendu au plan : ECR, EFS + 2 access points, S3 + CloudFront, SG, cluster ECS,
task def, service à 2 tasks, target group, règles de listener 200 et 201 sur les
DEUX listeners, secret Secrets Manager, rôle OIDC GitHub. **Aucune suppression**,
et surtout aucune ligne touchant la règle 60 ou un enregistrement Route53 existant.

⚠️ Le dossier de travail ne pointe que sur un backend à la fois. Après tout
`switch-backend.ps1 dev`, rebasculer sur prod, sinon le plan suivant vise
silencieusement le mauvais compte.

### 3.3 Injecter les secrets

Revenir au §2 maintenant que le secret existe.

---

## 4. CI/CD

### 4.1 Branche de déploiement

La trust policy OIDC de la prod n'accepte que `main` et `release/*`
(`github_deploy_branch_patterns`), et `deploy.yml` route `main` et `release/**`
vers l'environnement prod. Créer la branche de release depuis `develop` (opération
git, à faire par toi) :

```
release/2026-08
```

Note : `develop` est 4 commits devant `main`, et `main` porte 1 commit que
`develop` n'a pas. Décider du sort de ce commit avant de brancher.

### 4.2 Variables de dépôt GitHub

Settings → Secrets and variables → Actions → **Variables** :

| Variable | Valeur | Rôle |
|---|---|---|
| `AWS_ROLE_ARN_PROD` | `arn:aws:iam::381492212876:role/reactionpermis-prod-github-actions-app` | rôle assumé par OIDC (sortie `github_actions_app_role_arn`) |
| `SMOKE_HOST_PROD` | `preprod.reactionpermis.fr` | hôte canonique interrogé par le smoke test |
| `SMOKE_APEX_PROD` | *(laisser vide)* | assertion « apex → 301 », à ne remplir qu'au go-live |

Le smoke test reconnaît le 403 du verrou par IP : le runner n'est pas dans
l'allowlist, il le signale et n'affirme pas avoir validé l'application. Autoriser
les plages GitHub viderait le verrou de son sens.

### 4.3 Premier déploiement

Pousser `release/2026-08`. Le workflow build, pousse dans ECR (tags
`prod-<sha>-<ts>` **et** `latest`), force un nouveau déploiement, attend la
stabilité, puis vérifie qu'une cible est saine derrière l'ALB.

⚠️ La lifecycle policy ECR est `tagStatus = "any"`, keep-10 : la **profondeur de
rollback est limitée à 10 images**, tags versionnés et `latest` confondus.

---

## 5. Vérifications depuis l'IP autorisée

```powershell
curl.exe -s -o NUL -w "up    %{http_code}`n" https://preprod.reactionpermis.fr/up
curl.exe -s -o NUL -w "metier %{http_code}`n" https://preprod.reactionpermis.fr/test-psychotechnique
curl.exe -s -o NUL -w "http  %{http_code}`n" http://preprod.reactionpermis.fr/
curl.exe -s https://preprod.reactionpermis.fr/test-psychotechnique | Select-String "canonical"
```

Vérifier d'abord que le verrou est bien posé côté ALB. ⚠️ L'API ELBv2 ne remplit
`Values` que pour `host-header` et `path-pattern` : les CIDR d'une condition
`source-ip` ne vivent QUE dans `SourceIpConfig.Values`. Une requête sur `Values`
renvoie `null` et laisse croire à tort que le verrou n'est pas appliqué.

```powershell
aws elbv2 describe-rules --listener-arn $L443 --query "Rules[?Priority=='200'][].Conditions[].{field:Field,hosts:HostHeaderConfig.Values,ips:SourceIpConfig.Values}" --output json
aws elbv2 describe-rules --listener-arn $L80  --query "Rules[?Priority=='200'][].Conditions[].{field:Field,hosts:HostHeaderConfig.Values,ips:SourceIpConfig.Values}" --output json
```

Attendu sur chacun : deux conditions, `host-header` et `source-ip`.

Attendu : `200` sur `/up`, **`200` sur la page métier** (c'est la seule qui lit
MySQL, donc la seule qui prouve que le user `rp2026` et ses GRANT suffisent),
`301` sur le port 80, et un `<link rel="canonical">` en
`https://preprod.reactionpermis.fr/…`.

Puis, **depuis un autre réseau** (partage de connexion mobile), vérifier que le
verrou tient :

```
https://preprod.reactionpermis.fr/  → 403 « Accès restreint. »
http://preprod.reactionpermis.fr/   → 403 « Accès restreint. »
```

Le second est ce que CNTP n'avait pas : sans la règle 403 sur le listener 80, le
port 80 aurait atteint l'application malgré le verrou du 443.

Vérifier aussi que le site public n'a pas bougé :

```powershell
curl.exe -s -o NUL -w "apex %{http_code}`n" https://reactionpermis.fr/       # 301
curl.exe -s -o NUL -w "www  %{http_code}`n" https://www.reactionpermis.fr/   # 200
```

Logs applicatifs en cas de doute :

```powershell
aws logs tail /ecs/reactionpermis-prod-app --since 10m --filter-pattern "?ERROR ?Exception"
```

À parcourir à la main sur la pré-prod, parce que rien de tout ça ne le dira : le
back-office Filament sur `/admin` (CNTP y a découvert un 403 émis par le WAF de
l'ALB **après** son go-live, ce qui a bloqué toute édition de contenu), le tunnel
de réservation jusqu'à l'écran de paiement, et un échantillon d'URLs du sitemap.

---

## 5 bis. Résultats de la validation du 2026-08-25

Déploiement en ligne sur `preprod.reactionpermis.fr`. Sain :

- `/up` 200, `/` 200, **`/test-psychotechnique` 200 en 0,6 s** — c'est la seule
  page qui lit MySQL, donc la preuve que le user `rp2026` et ses GRANT suffisent.
- Port 80 → `301` vers https, **un seul saut, sans `:443`** : c'est bien nginx qui
  redirige, pas l'action `redirect` de l'ALB.
- `canonical` = `https://preprod.reactionpermis.fr/…`, donc `APP_URL` est juste.
- `<meta name="robots" content="noindex,nofollow">` présent : `APP_NOINDEX` agit.
- Site public intact : apex 301 → www, www 200, toujours servi par l'ancienne
  production (`Server: Apache/2.4.68`).

Le sitemap, les URLs legacy, les liens internes et les images relèvent de l'audit
de contenu, tenu à part dans **`docs/preprod-vs-prod.md`** — c'est là que vivent
les mesures et les fausses alertes déjà levées (dont le 404 attendu sur
`/livewire/livewire.js`).

**Le back-office fonctionne** — et le 403 qu'on obtient en le sondant est un
artefact de la sonde, pas un défaut.

`curl https://preprod.reactionpermis.fr/admin/login` renvoie `403` avec
`Server: awselb/2.0` et un corps générique de 118 octets. **La même requête avec
un User-Agent de navigateur renvoie `200`.** Le WAF `AAAEPWAF` attaché à l'ALB
partagé filtre les clients non-navigateur sur les chemins d'administration ; le
reste du site passe en `curl` sans problème, d'où l'illusion d'un blocage ciblé.

```powershell
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
curl.exe -s -o NUL -w "%{http_code}`n" -H "User-Agent: $UA" -H "Accept: text/html,application/xhtml+xml" https://preprod.reactionpermis.fr/admin/login
```

⚠️ **Toujours sonder `/admin` avec un User-Agent de navigateur.** Le même piège a
fait consigner un bloquant inexistant sur cntp-2026 pendant 12 jours après son
go-live (« aucune édition de contenu possible ») : `https://www.cntp.fr/admin/login`
répond 200 dès qu'on envoie un UA de navigateur. Vérifié le 2026-08-25.

La Web ACL est `AAAEPWAF`
(`arn:aws:wafv2:eu-west-3:381492212876:regional/webacl/AAAEPWAF/8081be37-2055-45a7-864a-ab30c11c412d`) :
deux règles de flood, `LyraWhitelist`, `Allow_URLs`, puis six groupes managés dont
`BotControlRuleSet`. Aucun `AdminProtectionRuleSet` — le filtrage vient du bot
control, pas d'une règle de chemin. **Rien à modifier.**

## 5 ter. Audit de cohérence préprod vs production

Sorti dans son propre document : **`docs/preprod-vs-prod.md`**. Il porte la
méthode, les mesures, les défauts corrigés et ce qui reste ouvert, et il est fait
pour être rejoué — après tout déploiement qui touche au contenu, puis une dernière
fois juste avant le go-live.

**État au 2026-08-25**, après les migrations `000120` à `000124` :

| Contrôle | Résultat |
|---|---|
| 574 URLs du sitemap de prod rejouées | **574 / 574 en 200 direct**, aucune redirection |
| Liens internes (10 pages) | **409 / 409 en 200** |
| Images du blog | toutes sur le bon CloudFront, toutes en 200 |

Reste ouvert : **104 URLs servies mais absentes du sitemap** — dont 96 pages
départementales de médecins, indexées aujourd'hui. Détail dans le document.

## 5 quater. Import du blog WordPress (traite le point A de l'audit)

Le blog legacy est un WordPress installé **sous `/post/`** sur le même domaine.
Deux choses à rapatrier : les articles, et les médias qu'ils référencent.

Migration : `database/migrations/2026_08_25_000120_import_legacy_wordpress_posts.php`.
Elle lit `reactionpermis_posts` / `reactionpermis_postmeta` et écrit dans
`rp2026_articles` (+ catégories, étiquettes, pivot). Non destructive : un slug déjà
présent est ignoré, jamais écrasé.

### 5q.1 Vérifications préalables

```sql
-- Les tables WordPress sont-elles sur la base par défaut, avec ce préfixe ?
SELECT table_name FROM information_schema.tables
 WHERE table_schema = 'aaaep_aaaeporganisme' AND table_name LIKE 'reactionpermis\_%';

-- 138 attendus (le nombre d'URLs /post/* du sitemap de production).
SELECT COUNT(*) FROM reactionpermis_posts WHERE post_type='post' AND post_status='publish';
```

Un écart sur le second compte se lit tout de suite : des articles en `draft`, ou
un `post_type` personnalisé. La migration échoue bruyamment si les tables sont
absentes ; `LEGACY_WP_IMPORT=off` permet de la sauter sur un environnement sans
WordPress.

### 5q.2 Médias — À FAIRE AVANT la migration

L'import écrit les URLs de destination, **il ne transfère aucun fichier**. Jouer
la migration sans avoir synchronisé le bucket produit 175 images en 404.

Les fichiers ont été récupérés le 2026-08-25 depuis le site legacy, qui les sert
publiquement — pas besoin d'accéder à l'EC2. 175 originaux, 29 Mo, tous JPEG/PNG
valides, dans `D:\reaction-permis\wp-uploads-export\blog\` en miroir de
l'arborescence `AAAA/MM/` de WordPress.

```powershell
aws s3 sync D:\reaction-permis\wp-uploads-export\blog s3://reactionpermis-prod-app-uploads-447bbbbf/blog/ --cache-control "public, max-age=31536000, immutable"

# Contrôle : une image doit répondre 200 via CloudFront.
curl.exe -s -o NUL -w "%{http_code}`n" https://d2yews0nw0bhiz.cloudfront.net/blog/2025/02/2_Conduire_en_milieu_urbain__conseils_pour_naviguer_dans_la_circulation.jpg
```

La collecte part des pages rendues (attributs `src` et `og:image`), pas de la
base. Les variantes de `srcset` ont été écartées : le profil `tiptap` ne whiteliste
pas cet attribut, seuls les fichiers en `src` sont donc servis. Pour une garantie
d'exhaustivité sur les images mises en avant, croiser avec la base :

```sql
SELECT DISTINCT meta_value FROM reactionpermis_postmeta WHERE meta_key = '_wp_attached_file';
```

⚠️ Le bucket de **dev** est distinct : y rejouer la migration sans y synchroniser
les mêmes fichiers donnera des images cassées sur `dev.reactionpermis.fr`.

### 5q.3 Import

⚠️ **Le `.env` utilisé pour la migration doit décrire l'environnement CIBLE, pas
le poste.** Les URLs des médias sont figées dans le HTML au moment de l'import :
un `.env` local en `UPLOADS_DISK=public` écrit des `/storage/blog/…` qui
répondront 404 en production, et rien ne le signale — le contenu s'importe, les
pages s'affichent, seules les images manquent. C'est arrivé au premier essai le
2026-08-25. Les deux migrations refusent désormais de tourner dans cette
configuration, mais autant la poser correctement :

```
UPLOADS_DISK=s3
AWS_BUCKET=reactionpermis-prod-app-uploads-447bbbbf
AWS_URL=https://d2yews0nw0bhiz.cloudfront.net
AWS_DEFAULT_REGION=eu-west-3
```

`AWS_URL` doit valoir **exactement** ce que porte la task def :

```powershell
$TD = (aws ecs describe-services --cluster reactionpermis-prod-cluster --services reactionpermis-prod-app --query "services[0].taskDefinition" --output text)
aws ecs describe-task-definition --task-definition $TD --query "taskDefinition.containerDefinitions[0].environment[?name=='AWS_URL'].value" --output text
```

Puis :

```powershell
php artisan migrate --force
aws ecs update-service --cluster reactionpermis-prod-cluster --service reactionpermis-prod-app --force-new-deployment
```

Le redéploiement n'est pas optionnel : les `Cache::forget()` et
`ResponseCache::clear()` des migrations n'agissent que sur la machine qui les
joue. En production les caches vivent sur l'EFS monté par les tasks, et c'est
`responsecache:clear` dans l'entrypoint du conteneur qui les purge au démarrage.
Les caches Eloquent (index, sitemap, alias de slugs) expirent seuls sous 10 min.

`2026_08_25_000121_repair_legacy_post_media_urls.php` réaligne les URLs déjà
écrites sur le disque d'uploads courant. Elle est **rejouable** : elle sert aussi
le jour où la distribution CloudFront est remplacée par un apply, ce qui change
son domaine et périme les URLs figées dans le contenu.

### 5q.4 Vérification

```powershell
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
curl.exe -s -o NUL -w "index %{http_code}`n" -H "User-Agent: $UA" https://preprod.reactionpermis.fr/post
curl.exe -s -o NUL -w "article %{http_code}`n" -H "User-Agent: $UA" https://preprod.reactionpermis.fr/post/les-defis-de-la-conduite-en-ville
```

Puis rejouer l'audit (`docs/preprod-vs-prod.md`). Mesuré le 2026-08-25 après
l'import : **574/574 en 200 direct**, et le sitemap de la préprod passé de 2358 à
**2502 URLs** (+138 articles, +7 guides, +2 hubs, +9 lexique, −12 termes qui
redirigent et sortent donc du sitemap).

### 5q.5 Les 77 redirections du plugin Redirection

La base porte aussi `reactionpermis_redirection_items` : **77 redirections 301
actives**, qui disparaissent avec le WordPress. Elles ne figurent dans aucun
sitemap — par construction, un sitemap ne liste que les URLs canoniques — mais
elles servent (compteurs `last_count` entre 700 et 1770).

Toutes relèvent du même motif : WordPress a changé sa règle de génération de
slugs. Les accents étaient translittérés et les apostrophes devenaient des tirets
(`qu-est-ce-qu-une-lettre-48si`), elles sont aujourd'hui supprimées
(`quest-ce-quune-lettre-48si`).

Plutôt que de recopier 77 lignes de configuration, `PostController::show()`
retrouve la cible **par comparaison normalisée** sur le chemin 404 :
dé-accentuation puis suppression de tout ce qui n'est pas alphanumérique. Vérifié
sur les 10 redirections les plus servies, 10/10 couvertes, et ça rattrape en prime
les variantes accentuées absentes du plugin. En cas de collision entre deux
articles, aucune redirection n'est émise : un 404 vaut mieux qu'une 301 vers le
mauvais article, qui serait invisible et durable.

⚠️ Une partie de ces redirections est **déjà cassée en production** : plusieurs
cibles ne correspondent à aucun article publié et répondent 404 aujourd'hui
(`/post/alcool-au-volant-quels-sont-les-risques-et-comment-se-defendre`,
`/post/guide-rapide-pour-reussir-son-examen-psychotechniques`,
`/post/une-securite-renforcee-pour-les-motards`, entre autres). Le mécanisme par
normalisation ne les ressuscite pas, mais il ne les dégrade pas non plus — et il
ne peut pas produire de 301 vers un 404, puisqu'il ne vise que des articles
existants. C'est donc strictement mieux que l'existant.

### 5q.6 Défaut corrigé au passage

`PostController` et `SitemapController` résolvaient la couverture d'article avec
`Storage::url()`, donc sur le disque **par défaut** — qui vaut `local` en
production, `FILESYSTEM_DISK` n'étant pas dans la task def. Les couvertures se
seraient rendues en `/storage/…`, un chemin que rien ne sert sur ECS. Les deux
appels passent désormais par `Storage::disk(config('uploads.disk'))`, comme le
reste du code et comme le prescrit `config/uploads.php`. Le défaut était invisible
tant qu'aucun article n'existait.

## 6. Ce qui reste avant le go-live

**Fait au 2026-08-25** : `/admin` validé (200 avec un UA de navigateur), contenu
du blog et pages CMS restaurés, audit de contenu à 574/574 et 409/409.

**Reste :**

- **Passer un paiement réel de bout en bout, IPN comprise.** C'est le seul chemin
  qui traverse `organisme_reservations` en écriture et l'API organisme, et le seul
  qu'aucune sonde HTTP ne couvre.
- **Décider du sort du mot de passe Lyra de production** qui s'est affiché en
  console le 2026-08-25. Le régénérer impose de changer
  `WEB_API_REACTION_LYRA_PWD` côté API organisme **au même moment** : désynchronisés,
  les clients sont débités sans que la réservation soit confirmée.
- **96 pages départementales de médecins absentes du sitemap** — indexées
  aujourd'hui, elles cesseraient d'être déclarées. Détail dans
  `docs/preprod-vs-prod.md`.
- **`permis-probatoire`** : seul terme du lexique sans cible de redirection, il
  garde donc une page autonome et le libellé générique. À trancher en back-office.
- `public/robots.txt` est un fichier **statique** : `APP_NOINDEX` n'agit que sur
  la balise meta. Sur la pré-prod le verrou par IP suffit (un crawler reçoit 403),
  mais il n'y a pas de second filet.
- Le go-live lui-même fait l'objet du runbook `RUNBOOK-golive-rp.md`.
