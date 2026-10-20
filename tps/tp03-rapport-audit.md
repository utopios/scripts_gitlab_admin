# TP03 — Génération d'un rapport d'audit des accès

**Module 03 — Audit des accès** · Durée : 70 min · Niveau : avancé

## Objectif

La direction sécurité vous demande un **rapport d'audit des accès** à l'instance GitLab, à produire
chaque mois. Vous écrivez un script en lecture seule qui collecte les données (API GitLab + annuaire
LDAP), applique des règles d'analyse, classe les écarts par criticité et génère un rapport Markdown
(lisible par un humain) et un fichier CSV (exploitable dans un tableur), puis vous proposez un plan de
remédiation.

## Prérequis

- VM de formation, accès SSH `formateur`, jeton root (`~/.gitlab-token`, scopes `api`, `sudo`).
- `/opt/formation/venv/bin/python` (python-gitlab, ldap3) ou `curl` + `jq` + `ldapsearch`.
- Compte de bind LDAP en lecture : `cn=gitlab-bind,ou=services,dc=formation,dc=lan` /
  `GitlabBind2026!` (à passer par variable d'environnement, jamais en dur dans le script).
- Répertoire de travail `~/tp03/`.
- Le TP02 a pu modifier l'instance (par exemple retirer `david.leroy` de `plateforme/backend`) : votre
  rapport doit rester juste quel que soit l'état de départ.

## Contexte

Politique d'accès de l'entreprise (référentiel de l'audit) :

1. Tout compte humain actif doit correspondre à une personne présente dans l'annuaire et membre de
   `cn=gitlab-users` ; les comptes locaux sont des exceptions à justifier.
2. Les administrateurs sont nominatifs, issus de l'annuaire, avec 2FA.
3. Un utilisateur externe n'a jamais un rôle supérieur à Developer.
4. Aucun jeton `sudo` ou `admin_mode` en dehors du compte d'administration principal ; aucun jeton à
   scope `api` valable plus de 90 jours.
5. Les clés de déploiement sont en lecture seule, sauf exception documentée.
6. Les clés SSH sont de type ed25519 (ou RSA ≥ 3072 bits).
7. Les jetons et clés proches de l'expiration (< 7 jours) sont signalés à leur propriétaire.

## Étapes

### Étape 1 — Collecte (20 min)

Écrivez `~/tp03/audit_acces.py` (ou un script Bash) qui collecte, **sans aucune écriture** :

1. tous les utilisateurs (y compris bloqués) avec : état, admin, externe, bot, identités, 2FA, dernière
   activité ;
2. les membres directs de tous les groupes et projets ;
3. les jetons actifs (personnels, de groupe, de projet) avec scopes, dates de création, d'expiration et
   de dernière utilisation ;
4. les clés de déploiement (avec les projets en écriture), les jetons de déploiement, les clés SSH de
   chaque utilisateur ;
5. pour chaque compte ayant une identité LDAP : existence de l'entrée et appartenance à `gitlab-users`.

Contrainte : la pagination doit être complète (vérifiez sur `/users` que vous obtenez le même nombre
que l'en-tête `X-Total`).

### Étape 2 — Analyse (20 min)

1. Traduisez chaque règle de la politique en un ou plusieurs contrôles.
2. Associez à chaque écart : une **criticité** (CRITIQUE, ÉLEVÉ, MOYEN, INFO), une **catégorie**, l'objet
   concerné, le constat, une **recommandation**.
3. Ajoutez des **indicateurs** : nombre de comptes actifs, d'administrateurs, d'externes, de comptes
   locaux, taux de 2FA, nombre de jetons actifs, de jetons jamais utilisés, de clés SSH sans expiration…
4. Prévoyez une option `--ignorer REGEX` pour exclure explicitement des exceptions acceptées (elles
   doivent apparaître dans l'en-tête du rapport).

### Étape 3 — Production du rapport (15 min)

1. Générez `rapport-audit-AAAAMMJJ.md` : en-tête (instance, version, date, exceptions), synthèse par
   criticité, indicateurs, tableau des écarts trié par criticité ; et `rapport-audit-AAAAMMJJ.csv`
   (séparateur `;`).
2. Le script renvoie un code retour non nul s'il existe au moins un écart CRITIQUE (pour pouvoir
   l'utiliser dans une tâche planifiée qui alerte).
3. Contrôlez que le rapport détecte **tous** les écarts volontairement présents sur l'instance (aucune
   liste n'est fournie : à vous de juger s'il en manque en revenant à la politique).

### Étape 4 — Plan de remédiation (15 min)

Rédigez `~/tp03/plan-remediation.md` : pour chaque écart CRITIQUE et ÉLEVÉ, l'action, l'outil
(UI, API, script du module 02…), le responsable et le délai. **N'appliquez pas** les actions : le module 04
(sécurisation des accès) part de cet état.

## Livrables

- `audit_acces.py` (ou équivalent), commenté.
- `rapport-audit-AAAAMMJJ.md` et `.csv` réellement générés.
- `plan-remediation.md`.

## Vérifications

| Contrôle | Commande | Attendu |
|---|---|---|
| Lecture seule | exécuter le script avec un jeton root de scope `read_api` (variable `GITLAB_TOKEN`), puis `sudo jq -r 'select(.token_id==<id du jeton>) \| .method' /var/log/gitlab/gitlab-rails/api_json.log \| sort \| uniq -c` | uniquement des `GET` ; révoquer ce jeton ensuite |
| Pagination | nombre d'utilisateurs lus = `X-Total` de `GET /users?per_page=1` | égal |
| Code retour | `./audit_acces.py …; echo $?` | `2` (il existe des écarts critiques) |
| CSV | `head -1 rapport-audit-*.csv` | `criticite;categorie;objet;constat;recommandation` |
| Couverture | `grep -c '^CRITIQUE;' rapport-audit-*.csv` | au moins 3 (6 sur une instance non modifiée) |
| Comptes cités | `grep -oE 'david.leroy|prestataire.ext|ancien.admin|bot-ci' rapport-audit-*.md \| sort -u` | les 4 comptes |
