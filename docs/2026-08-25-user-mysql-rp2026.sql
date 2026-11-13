-- User MySQL dédié à reactionpermis-2026 sur l'Aurora de PRODUCTION
-- (aaaep-db-mysql-v1-cluster, compte 381492212876, base aaaep_aaaeporganisme).
--
-- À jouer AVEC LE USER ADMIN, depuis le poste, avant le premier apply Terraform.
-- Ce n'est pas une migration Laravel : le conteneur ne joue jamais de migrations
-- (docker/entrypoint.sh), c'est précisément ce qui permet à ce user de n'avoir
-- AUCUN droit DDL.
--
-- Pourquoi un user dédié plutôt que `aaaep_aaaeporganisme` :
--   - attribution : sans user par application, `performance_schema.accounts`, le
--     PROCESSLIST et le slow log ne disent pas qui consomme quoi sur un cluster
--     partagé par cinq applications.
--   - plafond : MAX_USER_CONNECTIONS empêche une application d'épuiser le pool
--     du cluster pour toutes les autres.
--   - rayon de souffle : MySQL n'accepte pas de joker sur le nom de table dans un
--     GRANT. Un user capable de créer ses propres tables aurait donc forcément eu
--     le droit d'en détruire d'autres — y compris le legacy que personne ne sait
--     recréer. D'où : zéro DDL, migrations jouées à la main par l'admin.
--
-- Masque @'10.0.%' : une task ECS en subnet public joint l'endpoint RDS par son
-- IP PRIVÉE, dans le CIDR 10.0.0.0/16 du VPC aaaep. Un masque sur l'IP publique
-- ne matcherait jamais.

-- ─── 0. Vérifications préalables ────────────────────────────────────────────
-- a) Le journal de migrations `rp2026_migrations` ne doit PAS entrer en conflit.
--    Vérifier ce qui existe déjà et à qui c'est :
--      SELECT table_name FROM information_schema.tables
--       WHERE table_schema = 'aaaep_aaaeporganisme'
--         AND table_name IN ('migrations', 'rp2026_migrations', 'cntp2026_migrations');
--    S'il existe une table `migrations` générique, ne pas y toucher : elle
--    appartient à une autre application. rp2026 a le sien (config/database.php).
--
-- b) La table legacy `sitev3_pages` doit exister : la migration
--    2026_08_03_000101_seed_rp2026_seo_metas_from_legacy en lit les metas SEO.
--      SELECT COUNT(*) FROM sitev3_pages;

-- ─── 1. Création du user ────────────────────────────────────────────────────
-- Mot de passe : le générer aléatoirement, ne le coller nulle part ailleurs que
-- dans Secrets Manager (put-secret-value, cf. runbook §2). Il ne doit pas entrer
-- dans le tfstate ni dans un fichier versionné.
CREATE USER 'rp2026'@'10.0.%' IDENTIFIED BY 'MOT_DE_PASSE_A_GENERER';

-- 2 tasks × 16 workers php-fpm = 32 connexions en régime permanent, et jusqu'à
-- 4 tasks pendant un rollout ECS, soit 64 au pic. 80 laisse la marge sans
-- permettre à cette application d'assécher le cluster.
ALTER USER 'rp2026'@'10.0.%' WITH MAX_USER_CONNECTIONS 80;

-- ─── 2. Tables applicatives : DML complet, aucun DDL ────────────────────────
-- Les 13 tables créées par les migrations, plus la table pivot et le journal de
-- migrations. Pas de CREATE/ALTER/DROP/INDEX : les migrations sont jouées par
-- l'admin, pas par l'application.
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_users                 TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_password_reset_tokens TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_pages                 TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_articles              TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_article_tag           TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_categories            TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_tags                  TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_menus                 TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_menu_items            TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_site_settings         TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_home_settings         TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_social_links          TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_seo_metas             TO 'rp2026'@'10.0.%';
-- Commentaires du blog (DA-1719) : UPDATE pour la modération et l'effacement des IP,
-- DELETE pour la purge comments:purge et la suppression définitive.
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_comments              TO 'rp2026'@'10.0.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aaaep_aaaeporganisme.rp2026_faqs                  TO 'rp2026'@'10.0.%';
-- Journal des modifications : en ajout seul, une ligne écrite n'est jamais modifiée.
GRANT SELECT, INSERT ON aaaep_aaaeporganisme.rp2026_journal_modifications TO 'rp2026'@'10.0.%';

-- Lecture seule : l'application ne joue pas les migrations, mais Laravel lit ce
-- journal au boot de certaines commandes artisan (`migrate:status`, et le
-- `config:cache` ne le touche pas). SELECT suffit et évite qu'un `php artisan
-- migrate` lancé par erreur depuis le conteneur puisse écrire quoi que ce soit.
GRANT SELECT ON aaaep_aaaeporganisme.rp2026_migrations TO 'rp2026'@'10.0.%';

-- ─── 3. Tables legacy : lecture seule ───────────────────────────────────────
-- Périmètre tracé depuis le code (modèles Eloquent à `$table` explicite et
-- query builder). Toute nouvelle table legacy lue par l'application devra être
-- ajoutée ici, sinon l'erreur sera un SQLSTATE[42000] en production.
GRANT SELECT ON aaaep_aaaeporganisme.organisme_adresses     TO 'rp2026'@'10.0.%';
GRANT SELECT ON aaaep_aaaeporganisme.organisme_departements TO 'rp2026'@'10.0.%';
GRANT SELECT ON aaaep_aaaeporganisme.organisme_creneaux     TO 'rp2026'@'10.0.%';
GRANT SELECT ON aaaep_aaaeporganisme.organisme_sessions     TO 'rp2026'@'10.0.%';
GRANT SELECT ON aaaep_aaaeporganisme.medecin_infos          TO 'rp2026'@'10.0.%';
GRANT SELECT ON aaaep_aaaeporganisme.medecin_telephones     TO 'rp2026'@'10.0.%';
GRANT SELECT ON aaaep_aaaeporganisme.medecin_techniques     TO 'rp2026'@'10.0.%';
GRANT SELECT ON aaaep_aaaeporganisme.medecin_metas          TO 'rp2026'@'10.0.%';
GRANT SELECT ON aaaep_aaaeporganisme.insee_communes         TO 'rp2026'@'10.0.%';

-- ─── 4. Tables legacy : écriture strictement délimitée ──────────────────────
-- Réservation : le tunnel INSERT une ligne en etat = -3 (tentative non payée) et
-- la relit pour la page de retour (ReservationPaymentController:56 et :120).
-- PAS d'UPDATE, volontairement : c'est l'IPN, côté API organisme, qui fait
-- passer la réservation en payée. Donner l'UPDATE ici permettrait au site public
-- de marquer une réservation comme réglée.
GRANT SELECT, INSERT ON aaaep_aaaeporganisme.organisme_reservations TO 'rp2026'@'10.0.%';

-- Candidature médecin : formulaire public, INSERT seul. Sans SELECT, une faille
-- d'injection sur ce formulaire ne pourrait pas relire les candidatures déjà
-- déposées (MedecinController:504).
GRANT INSERT ON aaaep_aaaeporganisme.aaaep_medecin_candidats TO 'rp2026'@'10.0.%';

FLUSH PRIVILEGES;

-- ─── 5. Vérification ────────────────────────────────────────────────────────
SHOW GRANTS FOR 'rp2026'@'10.0.%';
-- 28 GRANT posés au total : 15 DML applicatifs, 1 SELECT+INSERT sur le journal
-- des modifications, 1 SELECT sur le journal des migrations,
-- 9 SELECT legacy, 1 SELECT+INSERT (réservations), 1 INSERT (candidatures).
-- SHOW GRANTS regroupe par jeu de privilèges, le nombre de LIGNES affichées sera
-- donc plus petit. Ce qui compte : la ligne `*.*` doit être un simple USAGE, et
-- aucune ligne ne doit porter CREATE, DROP, ALTER, INDEX ni REFERENCES.
