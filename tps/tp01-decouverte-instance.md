# TP01 — Découverte d'une instance GitLab

**Module 01 — Architecture et administration** · Durée : 70 min · Niveau : avancé

## Objectif

Vous prenez en charge une instance GitLab que vous ne connaissez pas. En une heure, vous devez être
capable de la décrire (version, composants, ports, stockage, journaux, authentification), de retrouver
n'importe quel dépôt sur disque, de suivre une requête de bout en bout dans les journaux et de savoir
ce que chaque outil d'administration laisse comme trace.

## Prérequis

- Votre VM de formation démarrée, `http://gitlab.formation.lan` accessible depuis votre poste.
- Connexion SSH à la VM avec le compte `formateur` (sudo sans mot de passe).
- Identifiants : `~/formation-credentials.txt` dans la VM ; jeton API root : `~/.gitlab-token`.
- Scripts du module déjà présents dans la VM, dossier `~/scripts/module01/` :
  `cartographie.sh`, `projet-sur-disque.sh`, `suivre-correlation.sh`, `action-trois-facons.sh`.
  Les commandes `./…` ci-dessous se lancent depuis ce dossier (`cd ~/scripts/module01`).

## Contexte

L'équipe plateforme vous confie l'instance `gitlab.formation.lan`. Avant toute intervention, la
responsable demande une **fiche d'instance** et la preuve que vous savez diagnostiquer une requête.

## Étapes

### Étape 1 — Cartographier l'instance (20 min)

1. Relevez, **à la main**, avec les commandes vues en cours :
   - la version exacte de GitLab et de Gitaly, et si la version du paquet est bloquée ;
   - la liste des services gérés par Omnibus et leur état ;
   - les ports TCP en écoute et le processus associé ; distinguez ceux qui écoutent sur toutes les
     interfaces de ceux limités à `127.0.0.1` ;
   - la place occupée par les dépôts, la base PostgreSQL, Prometheus et les journaux ;
   - la configuration LDAP (serveur, base, filtre utilisateur, compte de bind) **sans recopier le mot
     de passe**, et le résultat du contrôle LDAP.
2. Lancez ensuite `sudo ./cartographie.sh > ~/tp01/fiche-instance.md` et comparez avec vos relevés.
3. Répondez dans la fiche : quel composant écoute sur `127.0.0.1:8080` ? Par quoi passe une requête
   web avant d'y arriver ? Où est le socket de Gitaly ?

### Étape 2 — Retrouver un projet sur disque (10 min)

1. Récupérez l'ID du projet `ops/infra-scripts` par l'API (`GET /projects/:chemin_encodé`).
2. Calculez **vous-même** le chemin du dépôt dans le *hashed storage* (`sha256` de l'ID) et vérifiez
   qu'il existe sous `/var/opt/gitlab/git-data/repositories/`.
3. Vérifiez en base (table `project_repositories`) que le chemin est bien celui-là.
4. Affichez les branches du dépôt **en lecture seule**, avec le binaire Git embarqué et l'utilisateur `git`.
5. Comparez avec `sudo ./projet-sur-disque.sh ops/infra-scripts`.
6. Question : si l'on renomme le groupe `ops` en `exploitation`, que devient le chemin sur disque ?

### Étape 3 — Suivre un `git push` dans les journaux (20 min)

1. Créez un projet de test `tp01-<votre-prénom>` dans votre espace personnel root (UI ou API), avec un
   README.
2. Clonez-le en HTTP dans la VM, faites un commit et poussez-le en affichant les en-têtes HTTP
   (`GIT_TRACE_CURL=1`) pour récupérer le `X-Request-Id` de la requête `git-receive-pack`.
   Variante : retrouvez le correlation_id dans `gitlab-workhorse/current` (`uri` contenant
   `git-receive-pack`).
3. Avec `grep -rl` puis `jq`, listez **tous** les journaux qui contiennent ce correlation_id et, pour
   chacun, ce qu'il apprend (contrôleur, durée, méthodes gRPC…).
4. Retrouvez l'appel des hooks à l'API interne `/api/v4/internal/post_receive` et suivez-le jusqu'au
   job Sidekiq `Repositories::PostReceiveWorker` et au `CreatePipelineWorker`.
   Indice : le correlation_id change entre Gitaly et Rails pour les appels des hooks.
5. Vérifiez votre raisonnement avec `sudo ./suivre-correlation.sh <id> --suivre-hooks`.
6. Bonus : refaites l'exercice avec un push **SSH** (clé SSH ajoutée à votre utilisateur de test) et
   identifiez la ligne de `gitlab-shell/gitlab-shell.log` qui donne l'utilisateur, la clé et le projet.

### Étape 4 — Une même action, trois outils (20 min)

L'action étudiée : **bloquer** l'utilisateur de test `tp01-cobaye` (créé par le script s'il n'existe pas).

1. Lancez `sudo ./action-trois-facons.sh tp01-cobaye` : il bloque/débloque l'utilisateur par l'API puis
   par `gitlab-rails runner` et affiche ce qui a été journalisé.
2. Connecté en `root` dans le navigateur, bloquez `tp01-cobaye` depuis **Admin > Utilisateurs**, puis
   retrouvez la requête dans `production_json.log`. Débloquez-le ensuite.
3. Remplissez le tableau : pour chaque méthode, fichier(s) de journal, auteur visible, IP visible,
   correlation_id, durée approximative de l'opération.
4. Conclusion attendue (3 lignes) : quel outil privilégier pour une action courante, et quand la console
   Rails est-elle justifiée ?

## Livrables

- `~/tp01/fiche-instance.md` complétée de vos réponses (étapes 1 et 2).
- Un fichier `~/tp01/trace-push.md` : correlation_id(s), journaux concernés, chronologie du push
  jusqu'au pipeline.
- Le tableau comparatif de l'étape 4 et votre conclusion.

## Vérifications

| Contrôle | Commande | Résultat attendu |
|---|---|---|
| Version | `sudo gitlab-rake gitlab:env:info \| grep -E "^Version:"` | `Version:	19.4.2` |
| Dépôt de `ops/infra-scripts` | `sudo bash -c "ls -d /var/opt/gitlab/git-data/repositories/@hashed/4e/07/*.git"` | 2 lignes (`.git`, `.wiki.git`) si l'ID est 3 |
| Chemin en base | `sudo gitlab-psql -At -c "select disk_path from project_repositories where project_id=3"` | identique au chemin calculé |
| Trace du push | `sudo grep -rl <correlation_id> /var/log/gitlab` | au moins `gitlab-workhorse/current`, `gitlab-rails/production_json.log`, `gitaly/current` |
| Blocage UI | `sudo grep -h '/admin/users/tp01-cobaye/block' /var/log/gitlab/gitlab-rails/production_json.log \| jq -r .username` | `root` |
| État final | `curl -s -H "PRIVATE-TOKEN: $(cat ~/.gitlab-token)" "http://gitlab.formation.lan/api/v4/users?username=tp01-cobaye" \| jq -r '.[0].state'` | `active` |

## Nettoyage

Supprimez votre projet de test et l'utilisateur `tp01-cobaye` (UI ou API `DELETE /users/:id`).
