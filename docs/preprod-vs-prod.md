# Audit de cohérence — préprod vs production

Comparaison de `preprod.reactionpermis.fr` (stack reactionpermis-2026) avec
`www.reactionpermis.fr` (production actuelle), pour qu'aucune URL indexée ne se
mette à répondre 404 le jour de la bascule.

**Dernière mesure : 2026-08-26, sur la préprod DÉPLOYÉE** (migrations `000120` à
`000132`, correctifs SEO, prix, metas, sitemap et médecins en ligne).
Les chiffres ci-dessous sont ceux de cette mesure, pas d'un état antérieur.

---

## Méthode

1. Les **574 URLs du sitemap de production** sont rejouées une à une contre la
   préprod, en suivant les redirections. C'est l'inventaire de ce que Google
   connaît du site aujourd'hui.
2. Les **liens internes** de 10 pages représentatives (accueil, hubs, une page de
   chaque famille) sont extraits puis testés.
3. Les **images** d'un échantillon d'articles sont vérifiées jusqu'au CDN.
4. Les deux **sitemaps** sont comparés, pour repérer ce qui est servi mais plus
   déclaré.
5. Les **`title` et `meta description`** sont relevés URL par URL des deux côtés et
   comparés. **Ce contrôle manquait aux deux premiers passages**, et c'est lui qui a
   trouvé le défaut le plus coûteux de tout l'audit (voir plus bas). Un code 200 et
   un `canonical` juste ne disent rien de la balise que Google affichera.

Toutes les requêtes portent un User-Agent de navigateur : le WAF `AAAEPWAF` de
l'ALB refuse les clients non-navigateur sur les chemins d'administration, et un
`curl` nu y récolte un 403 qui n'a rien à voir avec l'application.

⚠️ **Confirmer tout défaut en série avant de le rapporter.** Une passe à 6
requêtes parallèles a produit un faux 404 sur `/favicon-16x16.png`, qui répond
200. Le parallélisme sert à dégrossir, pas à conclure.

---

## Résultat

| Contrôle | Résultat |
|---|---|
| 574 URLs legacy rejouées | **574 / 574 en 200 direct**, zéro anomalie |
| Liens internes (10 pages) | **409 / 409 en 200**, aucun lien cassé |
| Images du blog | toutes sur `d2yews0nw0bhiz.cloudfront.net`, toutes en 200 |
| Sitemap préprod | **2600 URLs** (2502 avant), dont 96 médecins et 96 départements |
| `lastmod` | **2243 / 2600** (157 avant) : la sonde de schéma a trouvé une colonne côté legacy |
| Titres du tunnel, 331 URLs | **284 identiques à la production (85,8 %)**, 47 divergent |
| Site public | intact, apex 301 → www, servi par l'ancienne prod |

Que les 574 répondent **en direct, sans un seul saut**, est le point important :
la structure d'URL du site est reprise à l'identique, la bascule ne fera pas
transiter le trafic indexé par des redirections.

### Composition du sitemap préprod

- 138 articles de blog
- 7 guides + 1 hub
- 1 hub lexique seul — les 12 termes redirigent et en sont exclus à dessein, et
  `permis-probatoire`, 13ᵉ terme sans cible, a été retiré le 26/08 (voir plus bas)
- le reste : familles dynamiques (départements, villes, centres, médecins)

---

## Défauts corrigés depuis le premier passage

Le premier audit, avant migrations, relevait quatre points. Trois sont clos.

**A. Les 138 articles du blog répondaient 404.** Le blog est un WordPress installé
sous `/post/` ; son contenu n'avait jamais été importé dans `rp2026_articles`.
Corrigé par `000120` (import) et `000121` (réalignement des URLs médias sur le
CDN). Les 175 médias référencés ont été recopiés dans le bucket d'uploads.

**B. Le menu pointait vers 5 pages inexistantes, sur tout le site.** Cause :
`2026_07_02_000061` s'était interrompu à sa 5ᵉ itération — la prod ne contenait
que les 4 premiers termes du tableau `$lexique`, dans l'ordre du tableau. MySQL
n'encapsulant pas les migrations dans une transaction, les insertions déjà faites
ont persisté et la migration a quand même été inscrite au journal. Les 2 hubs,
`permis-probatoire` et `guide-comprendre-le-test` relevaient d'autre chose :
aucune migration ne les créait, ils n'existaient en dev que saisis à la main.
Corrigé par `000122`, qui repose les 18 pages dans leur état final.

> **Leçon** : une migration inscrite au journal ne prouve pas que son effet est
> complet. Après un seed volumineux, compter les lignes plutôt que se fier au
> journal.

**D. `/cgv_pdf` répondait 404.** Défaut préexistant, non imputable à la bascule :
la production répond **500** sur cette même URL. Laissé en l'état.

### Fausses alertes levées

- `/livewire/livewire.js` en 404 est le **comportement normal** : Livewire 3
  n'enregistre cette route qu'en debug, sinon c'est `/livewire/livewire.min.js`.
- `/admin/login` en 403 vient du **User-Agent**, pas d'un blocage de chemin. Avec
  un UA de navigateur, la réponse est 200. Le même piège avait fait consigner un
  bloquant inexistant sur cntp-2026 pendant 12 jours après son go-live.

---

## Corrigés le 2026-08-26 (déployés, sauf mention contraire)

### Les 96 pages départementales de médecins n'étaient pas déclarées

Elles répondaient 200 et étaient déclarées dans le sitemap **de production** : après
la bascule elles auraient continué de fonctionner, mais auraient cessé d'être
annoncées. `SitemapController` n'avait aucune méthode pour cette famille.

Corrigé par `SitemapController::addMedecins()`, alimenté par
`ReservationController::departmentsReference()` filtré sur la métropole. Aucune
requête : la route accepte tout slug de la référence et rend un 200 même sans
médecin dans le département. Les fiches `medecin-coordonnees/{id}` restent hors
sitemap, comme en production.

### 3 départements du tunnel, et non 7

**Le premier relevé se trompait.** Sur les 7 URLs annoncées manquantes, 4
existaient déjà au sitemap préprod : `2A/corse-du-sud`, `2A/.../ajaccio`,
`2B/haute-corse`, `2B/.../bastia` y figuraient **en minuscules** (`2a`, `2b`), là où
le sitemap de production les porte en majuscules. Le `comm` de la première passe a
compté une différence de casse comme une absence.

Manquaient réellement 3 départements : **Creuse (23), Lozère (48), Nièvre (58)** -
ceux sans aucun centre actif, que la génération dérivait des centres. Le niveau
département est désormais déclaré pour toute la métropole, et **avant** la requête,
pour qu'une base injoignable n'emporte pas les 96 déclarations avec les villes.

### La casse était le vrai défaut : 4 URLs indexées en doublon

Le tunnel ne passait pas de `canonical` explicite : le layout retombe sur
`request()->path()`, donc chaque variante d'URL se déclarait elle-même canonique.
Or la route accepte le code sous plusieurs formes, et n'importe quel slug :

| URL | Réponse avant correctif | Canonical annoncé |
|---|---|---|
| `/test-psychotechnique/2A/corse-du-sud` | 200 | elle-même |
| `/test-psychotechnique/2a/corse-du-sud` | 200 | elle-même |
| `/test-psychotechnique/069/rhone` | 200 | elle-même |
| `/test-psychotechnique/69/n-importe-quoi` | 200 | elle-même |

Les deux premières sont un doublon réel et immédiat : Google connaît la forme
majuscule, `stepTwoPath()` - source des liens internes et du sitemap - produit la
minuscule. Les deux dernières sont une surface de doublons non bornée.

`renderStep2()` passe maintenant `canonical = stepTwoPath($code)` (+ `/{ville}`
quand le 4ᵉ segment est présent), c'est-à-dire la seule forme déclarée au sitemap.
Un `canonical` plutôt qu'un 301 : les URLs legacy indexées gardent leur 200 direct,
qui est la propriété que tout cet audit cherche à préserver.

### Même défaut sur les médecins : num contre slug

`/medecins-agrees/69` et `/medecins-agrees/rhone` répondaient tous deux 200 en
s'auto-canonicalisant, alors que les liens internes utilisaient le **num** et les
URLs indexées le **slug**. Deux conséquences : le signal interne pointait à côté de
la forme indexée, et le lookup `rp2026_seo_metas` - dont la clé est le chemin -
manquait les metas legacy quand on arrivait par le num.

Le slug fait désormais autorité : `canonical` et résolution des metas passent par
`/medecins-agrees/{slug}`, et les liens « départements voisins » de la page d'index
sont émis en slug. La redirection JS de l'autocomplete continue d'envoyer sur le
num - non crawlée, donc sans effet SEO, et le `canonical` couvre le cas.

### Le cache du sitemap survivait au déploiement

Défaut qui aurait rendu tout ce qui précède invisible. `SitemapController` cache son
XML en `rememberForever` - pas de TTL, invalidation par listeners sur
Page/Article/Category/Tag uniquement. Or le store est `CACHE_STORE=file` et
`storage/framework/cache` est un **montage EFS** (`ecs.tf`, access point `cache`) :
le cache est partagé entre tasks et persiste d'un déploiement à l'autre. Les
familles dérivées du code - départements, centres, médecins - n'ont aucun listener,
donc rien ne l'aurait purgé.

`docker/entrypoint.sh` fait maintenant `php artisan cache:forget sitemap_xml` au
boot, à côté du `responsecache:clear` qui existait pour la même raison.

### Les 557 pages du tunnel avaient perdu leurs metas

**Le défaut le plus coûteux de cet audit, et celui que les deux premiers passages
avaient laissé passer.** Ils validaient les codes de réponse et les `canonical` ;
aucun ne comparait les `title` à ceux de la production.

| URL | Production | Préprod (avant correctif) |
|---|---|---|
| `/test-psychotechnique/01/ain` | Test psychotechnique Ain (01) - Centres agréés | Choisir un créneau - Ain (01) |
| `…/01/ain/bourg-en-bresse` | Test psychotechnique Bourg-en-Bresse (01) | **Choisir un créneau - Ain (01)** |
| `…/02/aisne/saint-quentin` | Test psychotechnique Saint-Quentin (02) | **Choisir un créneau - Aisne (02)** |

Deux défauts distincts. La formulation indexée était perdue sur les 96 départements,
et surtout **les 461 pages villes servaient le titre de leur département** : 461 URLs
écrasées sur 96 titres, avec une description strictement identique partout.

`resources/views/reservation/step2.blade.php` figeait son titre, et
`ReservationController` n'importait même pas `SeoMetaResolver` — alors que les patrons
`test_departement` et `test_ville` existaient déjà dans `config/seo_patterns.php` sans
être appelés par personne, et que les metas legacy étaient déjà en base, importées de
`sitev3_pages` par `…_000101`. Preuve que la chaîne fonctionnait : les 96 pages
`/medecins-agrees/{dept}`, elles, appellent le résolveur, et leurs titres de préprod
sont **strictement identiques à ceux de la production**.

Corrigé : `renderStep2()` résout désormais les metas comme
`MedecinController::departement()`, avec le `canonical` normalisé pour clé. Effet de
bord traité dans le même geste : les deux patrons annonçaient « 95 € TTC », ce qui
aurait répliqué un prix faux dans jusqu'à 557 descriptions — le prix en a été retiré
(cf. `RP-A1` du backlog technique).

Garde-fou `tests/Feature/TunnelSeoMetasTest.php`, avec sa limite écrite : la page du
tunnel **n'est pas appelable en test**, elle lit les tables legacy `organisme_*` qui
n'ont aucune migration et n'existent donc pas sur SQLite.

### `/cgv_pdf` : corrigé et en ligne

Le point **D** du premier relevé est périmé. La route existe (`routes/web.php`,
commit `f0fb54a`), le PDF est versionné dans `public/`, et
`FooterAndLegalContentTest` couvre le cas. **Vérifié en ligne le 2026-08-26 : 200.**

### Garde-fou

`tests/Feature/SitemapCoverageTest.php` compte les URLs déclarées au lieu de faire
confiance au générateur : les 96 slugs de médecins un par un, les départements sans
centre (23, 48, 58) et les corses, l'absence des DOM. C'est l'application directe de
la leçon du point **B** ci-dessus.

Suite complète : **24 tests / 160 assertions au vert**, `pint --test` propre sur les
fichiers touchés (le dépôt a une dette Pint préexistante sur 23 autres fichiers,
hors périmètre). L'override sqlite de `phpunit.xml` a été vérifié actif avant de
lancer quoi que ce soit (lignes 26-27, plus `DB_URL` vidé).

---

### `permis-probatoire` retiré - arbitrage tranché le 2026-08-26

C'était le seul des 13 termes du lexique sans cible de redirection, parce que le seul
absent de `maquette-reference/pages/10-lexique.html` : il n'existait en dev que saisi
à la main dans Filament, et `000122` l'a reposé avec les autres pages manquantes sans
que son sort soit tranché. Sa carte affichait le libellé générique « Voir la
définition » au milieu de 12 cartes qui nomment leur destination.

**Retiré** par `2026_08_26_000128_remove_permis_probatoire_lexique_entry`. Le lexique
revient à la parité exacte avec la maquette : 12 termes, tous avec cible et libellé,
plus une seule occurrence de « Voir la définition » dans le hub.

Suppression définitive et non `delete()` Eloquent : `Page` utilise SoftDeletes, la
ligne masquée garderait son slug, sous contrainte unique. Même raisonnement que
`000110_remove_politique_confidentialites_page`, dont c'est le précédent.

**Aucun risque SEO, vérifié** : `/lexique-permis-test-psychotechnique/permis-probatoire`
n'existe pas en production et ne figure pas dans ses 574 URLs. Le sujet reste couvert
par `/post/quest-ce-que-le-permis-probatoire`, lui bien indexé et servi en 200.

Garde-fou : `tests/Feature/LexiqueRedirectionsTest.php` échoue si un terme de lexique
revient sans cible ni libellé. C'est l'invariant qui manquait et qui avait laissé
l'incohérence passer.

---

## Ce qui reste ouvert

### 🔴 `/index.php` répond 400 - correctif écrit, pas déployé

Régression introduite par le correctif de `RP-B2` lui-même. `return 301 /;` fait
construire à nginx un `Location` depuis son **scheme et son port réels** : derrière
l'ALB qui termine le TLS, cela donne `http://preprod.reactionpermis.fr:8080/`, donc
un mauvais scheme, un port interne exposé, et un **400 « plain HTTP request was sent
to HTTPS port »**.

C'est exactement le piège que `docker/nginx.conf` documente déjà pour l'action
redirect de l'ALB, et qu'il a fallu réintroduire pour le revoir. Corrigé en
`return 301 https://$host/;`, avec un test qui interdit désormais la cible nue,
`$server_port` et `$http_host`. **À déployer.**

> **Leçon** : `nginx -t` n'aurait rien vu. Ce n'était pas une erreur de syntaxe mais
> de sémantique, visible seulement à l'exécution derrière un terminateur TLS. Un
> `curl -sI` sur l'URL corrigée fait partie de la recette, pas seulement la
> validation de configuration.

### 🟡 47 pages villes sur 331 perdent leur titre indexé

Toutes le même motif : la production sert « **Tests** psychotechniques à Annonay (07)
| Réaction Permis », la préprod retombe sur le patron « Test psychotechnique à
Annonay (07) ». Aucune de ces 47 n'a de ligne dans `rp2026_seo_metas`.

Piste à vérifier - l'import `…_000101` filtre sur `page_type = 'DYNAMIQUE'`, ces
lignes sont peut-être en `STATIQUE` :

```sql
SELECT page_type, COUNT(*) FROM sitev3_pages
WHERE url LIKE '/test-psychotechnique/%/%/%' GROUP BY page_type;
```

**Arbitrage plutôt que défaut** : le titre de repli est correct, plus court, et mieux
calibré pour la SERP que la version avec suffixe de marque. À trancher, pas à
réparer d'office.

### 🟡 Le hub `/medecins-agrees` a son titre écrit en dur

`resources/views/medecins/index.blade.php` pose `title="Médecins agréés"` sans passer
par `SeoMetaResolver`, là où ses 96 pages départementales résolvent correctement et
retrouvent la formulation de production. La production sert
« Visite médicale | Réaction Permis ».

Même défaut que `RP-A7` : une page qui n'appelle pas le résolveur. Le patron
`medecins_hub` n'existe pas non plus.

### ⚪ Divergences volontaires, à ne pas « corriger »

- **Blog** : la préprod sert les metas du plugin SEO WordPress, mieux optimisées que
  le « Titre - Réaction Permis » de la production.
- **5 pages éditoriales** (accueil, les 3 situations, visite médicale) : formulations
  du plan SEO 2026, seedées par `…_000104`.
- **`/centre-psychotechnique`** : la production sert un `<title>` **vide**, la préprod
  le comble.

---

## Points clos depuis le premier passage

| Point | État |
|---|---|
| 138 articles de blog en 404 | clos (`000120`, `000121`) |
| Menu vers 5 pages inexistantes | clos (`000122`) |
| 96 pages médecins non déclarées | clos, `addMedecins()` |
| 3 départements du tunnel non déclarés | clos |
| Doublons de casse `2A`/`2a`, `069` | clos, `canonical` explicite |
| Doublon num/slug des médecins | clos, `/medecins-agrees/13` répond 404 |
| Cache du sitemap survivant au déploiement | clos, `cache:forget` à l'entrypoint |
| Metas des 557 pages du tunnel | clos, 284/331 identiques à la production |
| `permis-probatoire` | clos, retiré (`000132`… voir `000128`) |
| `/cgv_pdf` | clos, répond 200 |
| `/medecins-agrees/20` | clos, répond 404 |
| `lastmod` sur 6 % des URLs | clos, 2243 / 2600 |
| `/post/` | arbitré par le `rtrim` du gabarit |

---
## Rejouer l'audit

Les commandes tiennent en quelques lignes de shell ; l'essentiel est de partir du
sitemap de production et non d'une liste écrite à la main, sinon on ne teste que
ce à quoi on pense déjà.

```bash
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

curl -s -H "User-Agent: $UA" https://www.reactionpermis.fr/sitemap.xml -o prod.xml
grep -oE "<loc>[^<]*</loc>" prod.xml | sed 's|</\?loc>||g; s|https://www\.reactionpermis\.fr||' | sed 's|^$|/|' | sort -u > prod_paths.txt

while read p; do
  printf "%s " "$p"
  curl -s -o /dev/null -L --max-time 25 -H "User-Agent: $UA" \
    -w "%{http_code} (apres %{num_redirects} saut(s))\n" "https://preprod.reactionpermis.fr$p"
done < prod_paths.txt | grep -v " 200 (apres 0 "
```

La dernière ligne ne laisse passer que les anomalies : tout ce qui n'est pas un
200 direct.

**À refaire après tout déploiement qui touche au contenu**, et une dernière fois
juste avant le go-live — puis à nouveau après, en remplaçant l'hôte de préprod par
`www.reactionpermis.fr`.

**Comparer aussi les balises, et pas seulement les codes.** C'est le contrôle qui
manquait. La sonde est versionnée dans `D:\reaction-permis\audits\sondes\releve-metas.php`
et n'a besoin que de `prod_paths.txt` produit ci-dessus :

```bash
php releve-metas.php    # title / description, production vs préprod, URL par URL
```

Elle sépare trois cas : les régressions (la production a une meta, la préprod non), les
améliorations (la préprod comble un vide de production, ex. `/centre-psychotechnique`
dont le `title` est **vide en production**) et les divergences de formulation, à lire à
la main.

⚠️ **Comparer les deux inventaires en insensible à la casse.** C'est la casse de
`2A`/`2a` qui a fait consigner 7 URLs manquantes là où il n'y en avait que 3 :

```bash
comm -23 <(tr 'A-Z' 'a-z' < prod_paths.txt | sort -u) \
         <(tr 'A-Z' 'a-z' < pre_paths.txt  | sort -u)
```

Et attendre le déploiement avant de recompter : les correctifs du 2026-08-26
changent le générateur, pas la préprod actuellement en ligne. Compte attendu une
fois déployé : **+96 médecins, +3 départements**, soit 2601 URLs contre 2502.

