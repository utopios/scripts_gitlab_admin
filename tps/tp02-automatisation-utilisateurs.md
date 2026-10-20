# TP02 — Automatisation de la gestion des utilisateurs

**Module 02 — Automatisation de l'administration** · Durée : 75 min · Niveau : avancé

## Objectif

GitLab CE ne synchronise pas les groupes LDAP avec les groupes GitLab (fonction Premium). Vous allez
écrire et exploiter un script qui le fait : à partir de l'annuaire, il calcule les appartenances
attendues, les compare à GitLab et applique les écarts, en simulation puis en réel, de façon
idempotente et avec un rapport. Vous industrialiserez ensuite l'arrivée et le départ d'un collaborateur
et observerez le comportement natif de GitLab CE quand un compte quitte l'annuaire.

## Prérequis

- VM de formation, accès SSH `formateur`, jeton root dans `~/.gitlab-token`.
- Python : `/opt/formation/venv/bin/python` (python-gitlab, ldap3, pyyaml disponibles).
- Annuaire : `ldap://127.0.0.1:389`, base `dc=formation,dc=lan` ;
  compte de bind GitLab `cn=gitlab-bind,ou=services,dc=formation,dc=lan` / `GitlabBind2026!` (lecture) ;
  administrateur LDAP `cn=admin,dc=formation,dc=lan` / `LdapAdmin2026!` (écriture, étapes 4 à 6).
- Répertoire de travail `~/tp02/`. Le mot de passe de bind est passé par variable d'environnement :
  `export LDAP_BIND_PASSWORD='GitlabBind2026!'`.

## Contexte

Règle de gestion validée par la DSI :

| Groupe LDAP | Groupe GitLab | Niveau | Particularité |
|---|---|---|---|
| `dev-backend` | `plateforme/backend` | Developer | |
| `dev-frontend` | `plateforme/frontend` | Developer | |
| `ops` | `ops` | Maintainer | |
| `stagiaires` | `sandbox` | Developer | appartenance expirant à la fin de la formation (J+3) |

Contraintes : seul un membre de `gitlab-users` peut se connecter à GitLab ; les comptes locaux
(prestataires, comptes techniques) ne doivent jamais être modifiés par la synchronisation ; aucun
Owner ne doit être rétrogradé ; un membre ayant déjà un niveau supérieur le conserve.

## Étapes

### Étape 1 — État des lieux (10 min)

1. Listez les groupes LDAP et leurs membres (`ldapsearch -x -LLL -H ldap://127.0.0.1 -b ou=groups,dc=formation,dc=lan cn member`).
2. Listez les membres **directs** des quatre groupes GitLab cibles (API `GET /groups/:id/members`),
   puis les membres directs + hérités de `plateforme/backend` (`/members/all`).
3. Notez, à la main, les écarts attendus (ajouts, retraits, cas particuliers). Que penser de
   `david.leroy`, `prestataire.ext`, `bot-ci`, `hugo.lambert` ?

### Étape 2 — Le script de synchronisation (25 min)

1. Écrivez `~/tp02/mapping.yml` qui décrit la règle de gestion (connexion GitLab, connexion LDAP sans mot
   de passe, politique, liste des correspondances).
2. Écrivez `~/tp02/sync_ldap_groupes.py` (Python + ldap3 + python-gitlab recommandés ; Bash +
   `ldapsearch` + `curl` + `jq` accepté) qui :
   - lit les membres de chaque groupe LDAP (attribut `memberOf` des personnes, comme le filtre GitLab) ;
   - ignore (et signale) les personnes hors de `gitlab-users` ;
   - ajoute les membres manquants au bon niveau (avec expiration si demandée), corrige les niveaux ;
   - retire les membres directs absents du groupe LDAP **uniquement** s'ils ont une identité `ldapmain` ;
   - signale sans y toucher : comptes locaux, bots, Owners ;
   - accepte `--dry-run` (aucune écriture), `--create-missing` (crée le compte GitLab LDAP d'une personne
     autorisée qui ne s'est jamais connectée), `--rapport fichier.md` et `--csv fichier.csv` ;
   - journalise chaque décision avec un horodatage et renvoie un code ≠ 0 en cas d'erreur.
3. Si vous manquez de temps, demandez le script de référence au formateur et passez à l'étape 3 :
   l'important est l'exploitation.

### Étape 3 — Simulation, exécution, idempotence (10 min)

1. Lancez en `--dry-run` avec un rapport. Le plan correspond-il à votre analyse de l'étape 1 ?
2. Lancez en réel **sans** `--create-missing`, puis vérifiez dans GitLab.
3. Relancez immédiatement : combien d'actions d'écriture ? Pourquoi ?
4. Lancez avec `--create-missing` : que se passe-t-il pour les stagiaires ? Vérifiez la date
   d'expiration de leur appartenance à `sandbox`.

### Étape 4 — L'annuaire change (10 min)

1. Créez le nouvel arrivant `jules.nouveau` dans l'annuaire (fichier `~/tp02/jules.ldif`, puis
   `ldapadd -x -H ldap://127.0.0.1 -D cn=admin,dc=formation,dc=lan -w 'LdapAdmin2026!' -f jules.ldif`) :

   ```ldif
   dn: uid=jules.nouveau,ou=people,dc=formation,dc=lan
   objectClass: inetOrgPerson
   uid: jules.nouveau
   cn: Jules Nouveau
   givenName: Jules
   sn: Nouveau
   mail: jules.nouveau@formation.lan
   userPassword: Formation2026!
   ```
2. Ajoutez-le aux groupes `gitlab-users` et `dev-backend` (`ldapmodify`, `add: member`).
3. Relancez la synchronisation (dry-run puis réel, avec `--create-missing`).
4. Jules change d'équipe : retirez-le de `dev-backend`, ajoutez-le à `ops`. Relancez. Vérifiez le
   résultat dans GitLab et dans le rapport.

### Étape 5 — Comportement natif de GitLab CE (10 min)

1. Connectez-vous dans le navigateur avec `jules.nouveau` / `Formation2026!` (onglet « Annuaire
   Formation »). Le compte créé à l'étape 4 est-il réutilisé ? Créez-lui un jeton d'accès personnel
   (`read_api`, `read_repository`).
2. Retirez `jules.nouveau` de `gitlab-users`. Avec son jeton, faites immédiatement un
   `git ls-remote` sur `ops/infra-scripts` puis `GET /api/v4/user`. Est-il bloqué ? Pourquoi ?
3. Simulez une heure écoulée (**sur ce compte de test uniquement**) :
   `sudo gitlab-psql -c "update users set last_credential_check_at = now() - interval '2 hours' where username='jules.nouveau'"`,
   puis refaites l'appel API. État du compte ? Message dans quel journal ?
4. Essayez de le débloquer par l'API. Puis remettez-le dans `gitlab-users` et reconnectez-vous dans le
   navigateur. État du compte ?

### Étape 6 — Départ d'un collaborateur (10 min)

1. Écrivez (ou utilisez) `offboarding.py <username> [--dry-run] [--rapport f.md]` qui : bloque le compte,
   retire toutes ses appartenances directes, révoque ses jetons personnels actifs et supprime ses clés
   SSH, sans supprimer le compte.
2. Jules quitte l'entreprise : simulation, puis exécution réelle, puis relance (idempotence).
3. Relancez la synchronisation LDAP **sans** avoir retiré Jules des groupes LDAP : que fait-elle ?
4. Question : pourquoi bloquer plutôt que compter sur l'état `ldap_blocked` ?

## Livrables

- `mapping.yml`, `sync_ldap_groupes.py`, `offboarding.py`.
- Rapports : dry-run initial, exécution réelle, exécution après les changements de l'étape 4,
  offboarding de Jules.
- Réponses aux questions des étapes 1, 3, 5 et 6.

## Vérifications

| Contrôle | Commande | Attendu |
|---|---|---|
| Idempotence | relance du script | `0 action(s) d'écriture` |
| `david.leroy` retiré de `plateforme/backend` | `GET /groups/plateforme%2Fbackend/members` | absent |
| Comptes locaux intacts | idem | `prestataire.ext` (50) et `bot-ci` (40) toujours présents |
| Stagiaires | `GET /groups/sandbox/members` | `stagiaire01`… avec `expires_at` à J+3 |
| Jules dans `ops` | `GET /groups/ops/members` après étape 4 | `jules.nouveau` (40), absent de `plateforme/backend` |
| `ldap_blocked` | `GET /users?username=jules.nouveau` (étape 5.3) | `"state": "ldap_blocked"` |
| Offboarding | `GET /users?username=jules.nouveau` et `GET /users/:id/memberships` | `blocked`, `[]` |

Attention : l'état obtenu (david.leroy retiré de `plateforme/backend`) est volontairement conservé pour
le TP03. Ne lancez pas `gitlab-rake gitlab:cleanup:block_removed_ldap_users` (voir cours) : elle
bloquerait `david.leroy`.
