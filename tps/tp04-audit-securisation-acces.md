# TP 04 — Audit et sécurisation des accès

| | |
|---|---|
| **Module** | 04 — Sécurisation des accès |
| **Durée** | 60 à 75 minutes |
| **Niveau** | avancé |
| **Instance** | votre VM de formation, GitLab CE 19.4.2 (`http://gitlab.formation.lan`) |

## Objectif

Vous êtes l'administrateur de l'instance GitLab. La direction de la sécurité vous demande :

1. un **inventaire exhaustif** des moyens d'accès non interactifs (jetons, clés SSH, clés et
   jetons de déploiement, runners) ;
2. leur **confrontation à une politique** et un **plan d'actions** priorisé ;
3. la **rotation** du jeton d'un pipeline, sans casser le pipeline ;
4. le traitement d'un **secret commité** dans un dépôt ;
5. l'application des **réglages d'instance** de la politique, par l'API.

## Prérequis

- Connexion SSH à la VM avec le compte `formateur` (sudo sans mot de passe).
- Jeton administrateur dans `~/.gitlab-token` (scopes `api`, `sudo`, `admin_mode`).
- Outils présents dans la VM : `curl`, `jq`, `git`, `git filter-repo`,
  `/opt/formation/venv/bin/python` (modules `requests`, `pyyaml`, `tabulate`, `ldap3`).
- Mot de passe de l'administrateur LDAP : `~/formation-credentials.txt`.
- Module 04 (slides) : API des jetons, rotation, `POST /admin/token`, clés SSH.

Variables utiles pour toutes les étapes :

```bash
export T=$(cat ~/.gitlab-token)
export API=http://gitlab.formation.lan/api/v4
```

## Contexte

L'instance contient des comptes et des jetons créés « au fil de l'eau » : un compte `bot-ci`
qui sert de compte de service, un ancien administrateur, un développeur parti, un
prestataire externe, des clés RSA anciennes, une clé de déploiement en écriture… et un
mot de passe et un jeton commités puis « supprimés » dans `ops/infra-scripts`.

La politique de sécurité à appliquer est la suivante :

| Règle | Valeur |
|---|---|
| Expiration maximale d'un jeton (PAT, projet, groupe, déploiement) | **90 jours** |
| Jetons expirant dans moins de 7 jours | rotation à planifier |
| Jeton inutilisé depuis plus de 60 jours | révocation |
| Scopes sans justification | `read_api`, `read_repository`, `read_registry`, `read_user`, `self_rotate` |
| Scopes `sudo` / `admin_mode` | **uniquement** le compte `root` |
| Titulaire absent du groupe LDAP `gitlab-users`, bloqué ou désactivé | révocation immédiate |
| Compte humain utilisé comme compte de service (`bot-…`, `svc-…`, `ci-…`) | à remplacer |
| Clés SSH | DSA interdite, RSA **≥ 3072 bits**, expiration obligatoire |
| Clé de déploiement en écriture | à justifier |
| Réglages d'instance | expiration des PAT obligatoire, RSA ≥ 3072, DSA interdite, admin mode, 2FA admins, inscriptions fermées, mot de passe ≥ 12, jetons de runners 90 jours |

> Tous les objets que vous créez pendant ce TP sont préfixés `m04-`.

## Étapes

### Étape 1 — Inventaire des jetons (10 min)

1. Listez **tous** les jetons d'accès actifs de l'instance (jetons personnels, jetons de
   projet et de groupe, comptes de service) avec : id, nom, titulaire, scopes, date
   d'expiration, dernière utilisation.
2. Pour chaque titulaire, indiquez s'il s'agit d'un humain, d'un bot de jeton de
   projet/groupe ou d'un compte de service (`GET /service_accounts`).
3. Listez les jetons de déploiement (`GET /deploy_tokens`) et les runners
   (`GET /runners/all`).

### Étape 2 — Inventaire des clés (10 min)

1. Listez les clés SSH de **tous** les utilisateurs (il n'existe pas d'API « toutes les
   clés » : bouclez sur les utilisateurs) avec type, **longueur en bits**, empreinte SHA256
   et expiration.
2. Listez les clés de déploiement de l'instance (`GET /deploy_keys`) et les projets sur
   lesquels elles ont un accès **en écriture**.

### Étape 3 — Confrontation à la politique et plan d'actions (15 min)

1. Écrivez un script (Bash ou Python) qui applique les règles de la politique ci-dessus
   à l'inventaire des étapes 1 et 2, vérifie les réglages d'instance
   (`GET /application/settings`) et produit :
   - `inventaire-acces.csv` : une ligne par objet avec ses écarts ;
   - `plan-actions.md` : la liste des actions classées **P1** (immédiat), **P2** (sous
     7 jours), **P3** (à planifier).
2. Le contrôle « titulaire parti » se fait contre l'annuaire : membres de
   `cn=gitlab-users,ou=groups,dc=formation,dc=lan`.
3. Le script doit être **en lecture seule** et relançable.

### Étape 4 — Rotation du jeton d'un pipeline (15 min)

1. Créez un projet `m04-rotation-ci` (dans votre espace `root`) avec ce `.gitlab-ci.yml` :

   ```yaml
   lecture-api:
     tags: [shell]
     script:
       - 'code=$(curl -s -o reponse.json -w "%{http_code}" -H "PRIVATE-TOKEN: $API_TOKEN" "$CI_API_V4_URL/projects/$CI_PROJECT_ID")'
       - echo "HTTP $code"
       - test "$code" = 200
       - 'echo "Projet lu : $(jq -r .path_with_namespace reponse.json)"'
   ```
2. Créez un **jeton de projet** `m04-ci-lecture` conforme à la politique (scope et rôle
   minimaux, 30 jours) et une variable CI/CD `API_TOKEN` **masquée et protégée**.
3. Lancez un pipeline sur `main` : il doit réussir.
4. Faites **tourner** le jeton par l'API, en fixant explicitement la nouvelle expiration.
5. Prouvez que : l'ancien jeton est refusé ; un pipeline lancé **avant** la mise à jour de
   la variable échoue ; après mise à jour de `API_TOKEN`, le pipeline réussit à nouveau.
6. Question : que se passe-t-il si vous ne passez pas `expires_at` à la rotation ?

### Étape 5 — Secret commité dans `ops/infra-scripts` (15 min)

On travaille sur une **copie** pour ne pas altérer le projet d'origine.

1. Créez `root/m04-infra-scripts`, copie miroir (toutes les références) de `ops/infra-scripts`.
2. Recherchez dans **tout l'historique** de la copie les jetons `glpat-…` et les mots de
   passe : commit, fichier, ligne.
3. **Avant toute réécriture**, déterminez pour chaque jeton trouvé s'il est connu de
   l'instance (`POST /admin/token`) et révoquez-le si c'est le cas. Que faire pour
   `DB_PASSWORD` ?
4. Réécrivez l'historique avec `git filter-repo` pour faire disparaître `config/.env`,
   puis poussez en force (la branche `main` est protégée : autorisez temporairement le
   push forcé, puis rétablissez la protection).
5. Vérifiez par l'API si les anciens commits et l'ancien blob sont encore accessibles.
   Utilisez la fonction « Remove blobs » (GraphQL `projectBlobsRemove`) puis un
   housekeeping `prune`, et notez le résultat.
6. Bonus : sur une seconde copie, obtenez le même résultat **sans** réécriture locale
   (uniquement côté serveur).

### Étape 6 — Réglages d'instance (10 min)

1. Sauvegardez dans un fichier JSON la valeur actuelle des réglages visés par la politique.
2. Appliquez la politique par `PUT /application/settings`.
3. Vérifiez au moins trois effets concrets :
   - un jeton d'administrateur **sans** scope `admin_mode` (créez un utilisateur
     `m04-admin`) ne peut plus lire `/application/settings` ;
   - une clé RSA 2048 nouvelle est refusée ;
   - une clé RSA 2048 **déjà enregistrée** (créez `m04-dev` avec une telle clé avant
     l'application) : est-elle encore utilisable en SSH ? Conclusion ?
4. Restaurez les réglages d'origine à partir de votre sauvegarde (sur la VM de formation,
   l'admin mode et la 2FA gêneraient les autres TP).

### Étape 7 — Nettoyage

Supprimez tous les objets `m04-*` créés (projets, utilisateurs, comptes de service).

## Livrables

- `inventaire-acces.csv` et `plan-actions.md` ;
- le ou les scripts d'inventaire / de contrôle ;
- la trace de la rotation (identifiants des pipelines avant/après, codes HTTP) ;
- la trace du traitement du secret (jetons trouvés, révocation, état des objets avant/après purge) ;
- la sauvegarde JSON des réglages et la preuve de leur restauration.

## Vérifications

| Contrôle | Commande | Résultat attendu |
|---|---|---|
| Plan d'actions produit | `grep -c '^- \[ \]' plan-actions.md` | > 0, avec des actions P1 |
| Écarts majeurs détectés | `grep -E 'ancien.admin\|david.leroy\|bot-ci' plan-actions.md` | sudo hors root, titulaire parti, faux compte de service |
| Rotation effective | `curl -s -H "PRIVATE-TOKEN: $T" "$API/projects/<id>/access_tokens?state=inactive" \| jq length` | ≥ 1 jeton révoqué |
| Pipeline final vert | `curl -s -H "PRIVATE-TOKEN: $T" "$API/projects/<id>/pipelines?per_page=1" \| jq -r '.[0].status'` | `success` |
| Plus de secret dans la copie | `git clone -q http://oauth2:$T@gitlab.formation.lan/root/m04-infra-scripts.git /tmp/verif && git -C /tmp/verif log --all -p \| grep -c glpat-` | `0` |
| Réglages restaurés | `curl -s -H "PRIVATE-TOKEN: $T" $API/application/settings \| jq '{admin_mode,rsa_key_restriction}'` | valeurs d'origine (`false`, `0`) |
