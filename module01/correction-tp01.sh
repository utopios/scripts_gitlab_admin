#!/usr/bin/env bash

set -Eeuo pipefail

ICI=$(cd "$(dirname "$0")" && pwd)
OUT=$HOME/tp01
PRENOM=${PRENOM:-correction}
PROJET=tp01-$PRENOM
COBAYE=tp01-cobaye
URL=http://gitlab.formation.lan
A=$URL/api/v4
T=$(cat "$HOME/.gitlab-token")
ROOT_PW=${GITLAB_ROOT_PASSWORD:-$(sudo grep -oP "^GITLAB_ROOT_PASSWORD='\K[^']+" /opt/formation/formation.env)}
LOGS=/var/log/gitlab

api() { curl -sS -H "PRIVATE-TOKEN: $T" "$@"; }
etape() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
bloc() { printf '\n```text\n'; cat; printf '```\n'; }   # stdin -> bloc Markdown

# ---------------------------------------------------------------------------------------------
if [[ ${1:-} == --nettoyer ]]; then
  etape "Nettoyage"
  uid=$(api "$A/users?username=$COBAYE" | jq -r '.[0].id // empty')
  [[ -n $uid ]] && api -o /dev/null -w "utilisateur $COBAYE : %{http_code}\n" -X DELETE "$A/users/$uid?hard_delete=true"
  pid=$(api "$A/projects/root%2F$PROJET" | jq -r '.id // empty')
  if [[ -n $pid ]]; then
    api -o /dev/null -X DELETE "$A/projects/$pid"
    # la suppression est différée (30 jours) : suppression définitive immédiate
    full=$(api "$A/projects/$pid" | jq -r '.path_with_namespace')
    api -o /dev/null -w "projet $PROJET : %{http_code}\n" -X DELETE \
      "$A/projects/$pid?permanently_remove=true&full_path=$(jq -rn --arg v "$full" '$v|@uri')"
  fi
  rm -rf "$OUT/$PROJET" && echo "clone local supprimé"
  exit 0
fi

mkdir -p "$OUT"
cd "$ICI"

# =============================================================================================
etape "Étape 1 — Cartographie de l'instance"
sudo ./cartographie.sh > "$OUT/fiche-instance.md"
{
  echo; echo "# Relevés manuels (correction TP01)"
  echo; echo "## Version et blocage du paquet"
  { head -1 /opt/gitlab/version-manifest.txt
    dpkg-query -W -f='${Package} ${Version} (${Architecture})\n' gitlab-ce
    echo "paquets bloqués : $(apt-mark showhold | tr '\n' ' ')"
    sudo gitlab-rake gitlab:env:info | grep -E '^Version:|DB Version|Using LDAP'
    echo "Gitaly : $(sudo /opt/gitlab/embedded/bin/gitaly --version 2>/dev/null | sed -n 1p)"; } | bloc
  echo; echo "## Services gérés par Omnibus"
  sudo gitlab-ctl status | bloc
  echo; echo "## Ports TCP en écoute"
  sudo ss -Hltnp | awk '{split($6,a,"\""); print $4, a[2]}' | sort -t: -k2 -n -u | bloc
  echo; echo "Toutes interfaces (0.0.0.0 / [::]) : accessibles depuis le réseau ; 127.0.0.1 : local seulement."
  echo; echo "## Stockage"
  { df -h /var/opt/gitlab
    sudo du -sh /var/opt/gitlab/{git-data,postgresql,redis,gitaly,prometheus} /var/log/gitlab; } | bloc
  echo; echo "## Configuration LDAP (mot de passe masqué) et contrôle"
  { sudo sed -n "/ldap_enabled/,/^}/p" /etc/gitlab/gitlab.rb | grep -vE '^\s*#' \
      | sed -E "s/('password' *=> *)'[^']*'/\1'********'/"
    echo "---"; sudo gitlab-rake gitlab:ldap:check 2>&1 | sed -n '1,6p'; } | bloc
  echo; echo "## Réponses aux questions"
  socket=$(sudo grep -m1 -E '^\s*socket_path' /var/opt/gitlab/gitaly/config.toml | cut -d'"' -f2)
  cat <<EOF

- **Qui écoute sur 127.0.0.1:8080 ?** Puma (processus \`ruby\`), le serveur d'application Rails.
- **Par quoi passe une requête web avant ?** NGINX (port 80), puis gitlab-workhorse, qui traite
  lui-même les opérations lourdes (Git HTTP, téléchargements) et transmet le reste à Puma.
- **Socket de Gitaly :** \`${socket:-/var/opt/gitlab/gitaly/gitaly.socket}\` (socket Unix : invisible pour \`ss -t\`).
EOF
} >> "$OUT/fiche-instance.md"
echo "fiche : $OUT/fiche-instance.md"

# =============================================================================================
etape "Étape 2 — Retrouver ops/infra-scripts sur disque"
ID=$(api "$A/projects/ops%2Finfra-scripts" | jq -r .id)
H=$(echo -n "$ID" | sha256sum | cut -d' ' -f1)
D=/var/opt/gitlab/git-data/repositories/@hashed/${H:0:2}/${H:2:2}/$H.git
{
  echo; echo "# Étape 2 — ops/infra-scripts sur disque"
  { echo "ID du projet (API)        : $ID"
    echo "sha256(\"$ID\")            : $H"
    echo "chemin calculé            : $D"
    echo "existe sur disque         : $(sudo test -d "$D" && echo oui || echo NON)"
    echo "chemin en base            : $(sudo gitlab-psql -At -c "select disk_path from project_repositories where project_id=$ID")"
    echo "--- branches (lecture seule, git embarqué, utilisateur git)"
    sudo -u git /opt/gitlab/embedded/bin/git -C "$D" branch -a
    sudo -u git /opt/gitlab/embedded/bin/git -C "$D" log --oneline -3
    echo "--- vérification avec le script"
    sudo ./projet-sur-disque.sh ops/infra-scripts | sed -n '1,5p'; } | bloc
  cat <<'EOF'

**Renommer le groupe `ops` en `exploitation` ?** Le chemin sur disque **ne change pas** : il ne
dépend que de l'ID du projet (hashed storage). Seuls l'URL et la table `routes` changent ; le
renommage est donc instantané, sans déplacement de fichiers.
EOF
} >> "$OUT/fiche-instance.md"
echo "projet $ID → $D"

# =============================================================================================
etape "Étape 3 — Suivre un git push ($PROJET)"
if [[ -z $(api "$A/projects/root%2F$PROJET" | jq -r '.id // empty') ]]; then
  api -X POST "$A/projects" -d "name=$PROJET" -d initialize_with_readme=true | jq -c '{id,path_with_namespace}'
fi
rm -rf "$OUT/$PROJET"
git clone -q "http://root:$T@gitlab.formation.lan/root/$PROJET.git" "$OUT/$PROJET"
cd "$OUT/$PROJET"
echo "test $(date +%T)" >> notes.txt && git add . \
  && git -c user.name=correction -c user.email=correction@formation.lan commit -qm "push http (correction TP01)"
TRACE=$(GIT_TRACE_CURL=1 git push -q origin main 2>&1 || true)
cd "$ICI"
# X-Request-Id de la réponse au POST git-receive-pack
CID=$(printf '%s\n' "$TRACE" | awk '/Send header: POST .*git-receive-pack/{p=1} p && /Recv header: X-Request-Id/{print $NF; exit}' | tr -d '\r')
if [[ -z $CID ]]; then   # variante : depuis le journal de Workhorse
  sleep 2
  CID=$(sudo grep -h git-receive-pack $LOGS/gitlab-workhorse/current \
        | jq -r 'select(.msg=="access" and .method=="POST") | .correlation_id' | tail -1)
fi
echo "correlation_id du push : $CID"
sleep 8   # laisse Sidekiq traiter PostReceiveWorker et la création du pipeline
{
  echo "# Trace du push — $PROJET — $(date '+%F %T')"
  echo; echo "**correlation_id du \`POST git-receive-pack\`** : \`$CID\`"
  echo; echo "## Journaux contenant ce correlation_id"
  sudo grep -rl "$CID" $LOGS | sort | bloc
  echo; echo "## Méthodes gRPC appelées par Gitaly pour ce push"
  sudo grep -h "$CID" $LOGS/gitaly/current | jq -r '."grpc.method" // empty' | sort -u | bloc
  echo; echo "## Des hooks jusqu'au pipeline (suivre-correlation.sh --suivre-hooks)"
  sudo ./suivre-correlation.sh "$CID" --suivre-hooks 2>&1 | bloc
  cat <<'EOF'

## Chronologie

1. Le client envoie `POST /root/<projet>.git/git-receive-pack` : NGINX puis **Workhorse**, qui
   attribue le correlation_id (renvoyé dans `X-Request-Id`).
2. Workhorse demande l'autorisation à **Rails** (`git_receive_pack`, production_json.log), puis
   transmet le flux à **Gitaly** (`SSHReceivePack`/`PostReceivePack`, gitaly/current).
3. Les **hooks** de Gitaly appellent l'API interne (`/internal/allowed`, `pre_receive`,
   `post_receive`) : côté Rails, ces appels reçoivent un **nouveau correlation_id** (constat 19.4.2).
4. `post_receive` met en file **`Repositories::PostReceiveWorker`** (Sidekiq, même second
   correlation_id), qui déclenche **`CreatePipelineWorker`** : le pipeline est créé.
EOF
} > "$OUT/trace-push.md"
echo "trace : $OUT/trace-push.md"

# =============================================================================================
etape "Étape 4 — Bloquer $COBAYE par l'API, rails runner et l'interface"
sudo ./action-trois-facons.sh "$COBAYE" > "$OUT/etape4-api-runner.txt" 2>&1
echo "API + rails runner : $OUT/etape4-api-runner.txt"

# 4.2 Interface web : même requête qu'un navigateur (formulaire de connexion, puis bouton Block)
JAR=$(mktemp)
csrf() { grep -oP 'name="csrf-token" content="\K[^"]+' | head -1; }
curl -s -c "$JAR" -b "$JAR" "$URL/users/sign_in" | csrf > "$JAR.t"
curl -s -o /dev/null -c "$JAR" -b "$JAR" "$URL/users/sign_in" \
  --data-urlencode "authenticity_token=$(cat "$JAR.t")" \
  --data-urlencode "user[login]=root" --data-urlencode "user[password]=$ROOT_PW"
TOK=$(curl -s -c "$JAR" -b "$JAR" "$URL/admin/users/$COBAYE" | csrf)
code_ui=$(curl -s -o /dev/null -w '%{http_code}' -c "$JAR" -b "$JAR" -X PUT \
  -H "X-CSRF-Token: $TOK" -H 'Accept: application/json' "$URL/admin/users/$COBAYE/block")
sleep 2
LIGNE_UI=$(sudo grep -h "/admin/users/$COBAYE/block" $LOGS/gitlab-rails/production_json.log \
  | tail -1 | jq -c '{time,method,path,controller,action,status,username,remote_ip,correlation_id,duration_s}')
TOK=$(curl -s -c "$JAR" -b "$JAR" "$URL/admin/users/$COBAYE" | csrf)
curl -s -o /dev/null -c "$JAR" -b "$JAR" -X PUT -H "X-CSRF-Token: $TOK" -H 'Accept: application/json' \
  "$URL/admin/users/$COBAYE/unblock"
rm -f "$JAR" "$JAR.t"
echo "interface web : blocage HTTP $code_ui, puis déblocage"

{
  echo "# Étape 4 — Une même action, trois outils ($COBAYE)"
  echo; echo "## API REST et gitlab-rails runner (action-trois-facons.sh)"
  bloc < "$OUT/etape4-api-runner.txt"
  echo; echo "## Interface web (Admin > Users > $COBAYE > Block) — ligne de production_json.log"
  echo "$LIGNE_UI" | bloc
  cat <<'EOF'

## Tableau comparatif

| Méthode | Journal | Auteur visible | IP visible | correlation_id | Durée |
|---|---|---|---|---|---|
| API REST | `api_json.log` (+ workhorse, nginx) | oui (`username`, type et id du jeton) | oui | oui (`X-Request-Id`) | quelques dizaines de ms |
| Interface web | `production_json.log` (+ workhorse, nginx) | oui (`username`) | oui | oui | quelques dizaines de ms |
| `gitlab-rails runner` | aucune requête HTTP ; seul le job Sidekiq déclenché | **non** | **non** | identifiant hexadécimal sans lien avec un utilisateur | 15 à 30 s (démarrage de Rails) |

## Conclusion

Pour une action courante, on privilégie **l'API** (scriptable, traçable : auteur, jeton, IP,
correlation_id) ou l'interface pour un geste ponctuel. La **console Rails** ne laisse presque aucune
trace et contourne les contrôles : on la réserve aux cas sans autre voie (réparation, donnée
inaccessible par l'API), et on consigne ce qu'on y a fait dans un ticket.
EOF
} > "$OUT/comparatif.md"
echo "comparatif : $OUT/comparatif.md"

# =============================================================================================
etape "Vérifications (tableau de l'énoncé)"
ok() { printf '  [%s] %s\n' "$1" "$2"; }
v=$(sudo gitlab-rake gitlab:env:info 2>/dev/null | awk '/^Version:/ && !f {print $2; f=1}')   # 1re ligne = GitLab (sans couper le pipe)
ok "$([[ -n $v ]] && echo OK || echo KO)" "Version : $v"
n=$(sudo bash -c "ls -d ${D%.git}*.git" | wc -l)
ok "$([[ $n -ge 1 ]] && echo OK || echo KO)" "Dépôt de ops/infra-scripts (ID $ID) : $n répertoire(s) .git"
db=$(sudo gitlab-psql -At -c "select disk_path from project_repositories where project_id=$ID")
ok "$([[ "/var/opt/gitlab/git-data/repositories/$db.git" == "$D" ]] && echo OK || echo KO)" "Chemin en base identique au chemin calculé ($db)"
nb=$(sudo grep -rl "$CID" $LOGS | grep -cE 'gitlab-workhorse/current|production_json.log|gitaly/current' || true)
ok "$([[ $nb -ge 3 ]] && echo OK || echo KO)" "Trace du push : workhorse, production_json et gitaly contiennent $CID"
u=$(echo "$LIGNE_UI" | jq -r '.username // empty')
ok "$([[ $u == root ]] && echo OK || echo KO)" "Blocage UI journalisé avec l'auteur : ${u:-absent}"
etat=$(api "$A/users?username=$COBAYE" | jq -r '.[0].state')
ok "$([[ $etat == active ]] && echo OK || echo KO)" "État final de $COBAYE : $etat"

echo
echo "Livrables : $OUT/fiche-instance.md  $OUT/trace-push.md  $OUT/comparatif.md"
echo "Nettoyage  : ./correction-tp01.sh --nettoyer"
