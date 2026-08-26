# Runbook — Go-live de reactionpermis-2026 sur reactionpermis.fr

Bascule de l'ancienne production (règle ALB priorité 60) vers le stack
`reactionpermis-2026`, sur le même ALB `aaaep-site-web-alb`, compte prod
`381492212876`.

À n'exécuter qu'après le runbook de pré-prod
(`RUNBOOK-2026-08-25-preprod-rp.md`) et sa validation complète.

## Ce qui rend cette bascule sûre

Le DNS n'a **rien à changer** : `reactionpermis.fr` et `www.reactionpermis.fr`
résolvent déjà vers les deux IP de `aaaep-site-web-alb` (vérifié le 2026-08-25,
mêmes IP que `cntp.fr` et `psychologue.aaaep.fr`). La bascule se joue entièrement
sur les règles du listener 443 : instantanée, et réversible en une commande.

Et l'apply Terraform ne change rien pour les visiteurs : notre règle est en
priorité 200, l'ancienne en 60, et l'ALB évalue par priorité croissante.
L'ancienne gagne tant qu'elle existe. On prépare à froid, on vérifie, on bascule.

L'ancienne production n'est **pas** décommissionnée : son target group, ses
instances et ses données restent intacts pendant toute l'opération. C'est ce qui
rend le retour arrière sûr.

---

## 1. Relevés à conserver AVANT toute manipulation

```powershell
$L443 = "arn:aws:elasticloadbalancing:eu-west-3:381492212876:listener/app/aaaep-site-web-alb/da203a6f6728345c/e4bbf9f610ffb951"
$L80  = "arn:aws:elasticloadbalancing:eu-west-3:381492212876:listener/app/aaaep-site-web-alb/da203a6f6728345c/1391cfd4ea9deb2b"

# La règle historique à supprimer. Elle n'est dans AUCUN état Terraform : ce
# relevé est la seule chose qui permettra de la recréer.
aws elbv2 describe-rules --listener-arn $L443 `
  --query "Rules[?Priority=='60']" --output json `
  | Tee-Object -FilePath .\regle-alb-60-reactionpermis.json
Get-Content .\regle-alb-60-reactionpermis.json
```

**✅ Relevé le 2026-08-25** — la règle a bien la forme attendue, les deux hôtes
dans une seule règle :

```
RuleArn  : arn:aws:elasticloadbalancing:eu-west-3:381492212876:listener-rule/app/aaaep-site-web-alb/da203a6f6728345c/e4bbf9f610ffb951/a08d08a6265b236c
Priorité : 60
Hosts    : reactionpermis.fr, www.reactionpermis.fr
Action   : forward → arn:aws:elasticloadbalancing:eu-west-3:381492212876:targetgroup/tg-PROD-reactionpermis-fr/e629a2dd47c18014
```

Sauvegarde locale : `D:\reaction-permis\regle-alb-60-reactionpermis.json` (hors
dépôt). Re-vérifier ces valeurs juste avant la bascule : la règle vit hors
Terraform, rien n'empêche qu'elle ait changé entre-temps.

Relever aussi ce que fait le listener 80 pour ces hôtes — aujourd'hui
`http://reactionpermis.fr` répond `301` vers `https://reactionpermis.fr`, mais
cette redirection peut venir de la règle 9 comme de l'origine derrière l'action
par défaut :

```powershell
aws elbv2 describe-rules --listener-arn $L80 `
  --query "Rules[].{p:Priority,cond:Conditions,act:Actions[0].Type}" --output json
```

Si une règle de priorité inférieure à 200 couvre déjà ces hôtes en redirect, elle
continuera de gagner sur la nôtre : comportement inchangé, rien à faire. Sinon,
c'est notre règle 200 qui prendra le relais et nginx émettra la redirection.

---

## 2. Basculer `envs/prod.tfvars`

| Variable | Avant (pré-prod) | Après (go-live) |
|---|---|---|
| `app_fqdn` | `preprod.reactionpermis.fr` | `www.reactionpermis.fr` |
| `app_additional_hosts` | `[]` | `["reactionpermis.fr"]` |
| `app_allowed_source_ips` | `["x.x.x.x/32"]` | `[]` |
| `app_acm_certificate_domain` | `"reactionpermis.fr"` | inchangé |
| `app_route53_zone_id` | l'ID de la zone | `""` |
| `app_extra_env.APP_NOINDEX` | `"true"` | `"false"` |

Quatre points méritent d'être compris plutôt que copiés :

- **`www` et non l'apex dans `app_fqdn`.** `app_fqdn` ne sert pas qu'au routage :
  il alimente `APP_URL`, d'où Laravel tire le canonical, `og:url` et les `<loc>`
  du sitemap. Or `docker/nginx.conf` renvoie l'apex nu en 301 vers `www`. Mettre
  l'apex ici ferait déclarer à chaque page une URL canonique redirigée — un défaut
  invisible, le site répondrait 200 partout.
- **Les deux hôtes restent dans la même règle** (`concat(app_fqdn,
  app_additional_hosts)`), comme la règle 60 qu'on remplace.
- **`app_route53_zone_id` repasse à `""`.** Les enregistrements de
  `reactionpermis.fr` existent déjà et sont gérés hors Terraform depuis toujours.
  Les adopter n'apporterait rien et rendrait un retour arrière dangereux : une
  erreur sur cet état supprimerait l'apex du domaine. Effet de bord voulu : l'alias
  `preprod.reactionpermis.fr` est détruit.
- **`APP_NOINDEX` à `"false"`.** L'oublier mettrait
  `<meta name="robots" content="noindex,nofollow">` sur toute la production.

---

## 3. Appliquer Terraform (sans effet visible)

```powershell
cd D:\reaction-permis\reactionpermis-aws
.\switch-backend.ps1 prod
.\tf.ps1 prod plan
.\tf.ps1 prod apply
```

Attendu au plan :

- règle 200 (443 et 80) : conditions modifiées — hosts `www.reactionpermis.fr` +
  `reactionpermis.fr`, plus de condition `source_ip`
- règles 201 (les deux 403 du verrou) : **détruites**, la liste d'IP étant vide
- alias Route53 `preprod.reactionpermis.fr` : **détruit**
- rien sur le certificat : le stack consomme celui de la fondation depuis la
  pré-prod, son SAN `*.reactionpermis.fr` couvrait preprod et son SAN `www` +
  l'apex couvrent le go-live
- task definition remplacée (`APP_URL` et `APP_NOINDEX` changent)

**Ne rien appliquer si le plan touche la règle 60, un target group qui n'est pas
le nôtre, ou un enregistrement Route53 existant.**

À ce stade `reactionpermis.fr` sert toujours l'ancien site.

---

## 4. Vérifier à froid

```powershell
aws ecs wait services-stable --cluster reactionpermis-prod-cluster --services reactionpermis-prod-app

$TG = (aws ecs describe-services --cluster reactionpermis-prod-cluster --services reactionpermis-prod-app `
        --query "services[0].loadBalancers[0].targetGroupArn" --output text)
aws elbv2 describe-target-health --target-group-arn $TG `
  --query "TargetHealthDescriptions[].{cible:Target.Id,etat:TargetHealth.State}" --output table
```

**Ne pas basculer tant que deux cibles ne sont pas `healthy`.**

---

## 5. Basculer

```powershell
aws elbv2 delete-rule --rule-arn arn:aws:elasticloadbalancing:eu-west-3:381492212876:listener-rule/app/aaaep-site-web-alb/da203a6f6728345c/e4bbf9f610ffb951/a08d08a6265b236c
```

Effet immédiat : plus rien ne matche `reactionpermis.fr` avant la priorité 200,
le trafic part sur notre target group.

---

## 6. Vérifier tout de suite

⚠️ L'hôte canonique est `www.reactionpermis.fr` : l'apex répond `301`.
Interroger l'apex en attendant un `200` ferait échouer la vérification sur une
redirection parfaitement légitime.

```powershell
curl.exe -s -o NUL -w "apex   %{http_code}`n" https://reactionpermis.fr/                      # 301
curl.exe -s -o NUL -w "www    %{http_code}`n" https://www.reactionpermis.fr/                  # 200
curl.exe -s -o NUL -w "metier %{http_code}`n" https://www.reactionpermis.fr/test-psychotechnique  # 200
curl.exe -s -o NUL -w "http   %{http_code}`n" http://www.reactionpermis.fr/                   # 301
curl.exe -sI https://www.reactionpermis.fr/ | Select-String -Pattern "x-robots"
curl.exe -s https://www.reactionpermis.fr/ | Select-String -Pattern "noindex","canonical"
```

Attendu : `301` sur l'apex et sur le port 80, `200` sur www, **aucun** `noindex`,
et un canonical en `https://www.reactionpermis.fr/…`. La page métier est celle qui
compte : c'est la seule qui lit la base.

Vérifier aussi le back-office, `/admin` : CNTP a découvert **après** son go-live
que l'ALB y renvoyait un 403 (WAF sur les chemins d'administration), ce qui a
bloqué toute édition de contenu.

```powershell
curl.exe -s -o NUL -w "admin %{http_code}`n" https://www.reactionpermis.fr/admin/login
curl.exe -s -o NUL -w "livewire %{http_code}`n" https://www.reactionpermis.fr/livewire/livewire.js
```

Un 403 avec `Server: awselb/2.0` et un corps générique de ~118 octets = c'est
l'ALB, pas l'application :
`aws wafv2 get-web-acl-for-resource --resource-arn <arn-alb> --region eu-west-3`.

**Contrôler les balises, pas seulement les codes.** Un `200` et un `canonical` juste
ne disent rien du `title` que Google affichera. C'est ce contrôle manquant qui a laissé
passer, jusqu'au 2026-08-26, le fait que **les 461 pages villes servaient le titre de
leur département**. Trois URLs suffisent à le voir :

```powershell
foreach ($u in @("/test-psychotechnique/01/ain",
                 "/test-psychotechnique/01/ain/bourg-en-bresse",
                 "/medecins-agrees/rhone")) {
  $html = curl.exe -s "https://www.reactionpermis.fr$u" | Out-String
  if ($html -match "<title>(.*?)</title>") { $t = $Matches[1] } else { $t = "PAS DE TITLE" }
  "{0,-46} {1}" -f $u, $t
}
```

Attendu : un titre **propre à chaque URL**, la ville ne reprenant jamais celui de son
département. Le relevé complet se fait avec
`D:\reaction-permis\audits\sondes\releve-metas.php` (voir `preprod-vs-prod.md`).

---

## 7. Retour arrière, si besoin

Une seule commande, effet immédiat. La garder ouverte dans un autre terminal
**avant** de basculer :

```powershell
aws elbv2 create-rule --listener-arn $L443 --priority 60 --conditions Field=host-header,Values=reactionpermis.fr,www.reactionpermis.fr --actions Type=forward,TargetGroupArn=arn:aws:elasticloadbalancing:eu-west-3:381492212876:targetgroup/tg-PROD-reactionpermis-fr/e629a2dd47c18014
```

Le `RuleArn` d'origine ne peut pas être réutilisé — AWS en attribue un nouveau.
Ce qui compte est reproduit à l'identique : priorité, hôtes, target group.

---

## 8. Après la bascule

- **Variables GitHub** : `SMOKE_HOST_PROD` → `www.reactionpermis.fr`,
  `SMOKE_APEX_PROD` → `reactionpermis.fr` (active l'assertion « apex → 301 » du
  smoke test).
- **Surveiller la première heure** :
  `aws logs tail /ecs/reactionpermis-prod-app --since 10m --filter-pattern "?ERROR ?Exception"`
- **Paiement de bout en bout** avec les vraies clés Lyra, IPN comprise : c'est le
  seul chemin qui traverse `organisme_reservations` en écriture et l'API organisme.
- **Ne décommissionner l'ancienne production qu'après plusieurs jours** — c'est le
  filet. Sur CNTP elle a été gardée, et le go-live de `psychologue.aaaep.fr` avait
  laissé exprès une règle ALB de rollback.
- **`public/robots.txt` est statique** : vérifier qu'il n'interdit rien, `APP_NOINDEX`
  n'agit que sur la balise meta.
- 🔴 **La mesure s'arrête à la bascule.** L'ancienne production charge **GA4
  `G-S6E8D9TWRE` et GTM `GTM-KGBGDR39`** (`reactionpermis-site/resources/views/includes/meta.blade.php`) ;
  rp2026 ne charge **aucun traqueur**. Dès la bascule, la propriété GA4 et le conteneur
  GTM cessent de recevoir des données, et l'historique devient incomparable. Prévenir
  avant, pas après. ⚠️ L'ancienne production les charge **sans aucun bandeau de
  consentement** : les remettre en place sans en profiter pour ajouter le recueil
  rétablirait un manquement connu (cf. `RP-C1` du backlog technique).
