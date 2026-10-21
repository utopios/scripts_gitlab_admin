#!/usr/bin/env bash
# Fonctions communes aux scripts du module 09 (à "sourcer").
# Jeton : variable GITLAB_TOKEN, sinon ~/.gitlab-token (jeton root de la VM de formation).
set -euo pipefail
GITLAB_URL="${GITLAB_URL:-http://gitlab.formation.lan}"
API="$GITLAB_URL/api/v4"
GITLAB_TOKEN="${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}"
M09_DIR="${M09_DIR:-$HOME/m09-jenkins}"      # répertoire de travail (secrets, cookies...)
SECRETS="$M09_DIR/secrets"                   # monté en lecture seule dans /run/secrets du conteneur
JENKINS_NAME="${JENKINS_NAME:-m09-jenkins}"
JENKINS_PORT="${JENKINS_PORT:-8090}"
VM_IP="${VM_IP:-$(hostname -I | awk '{print $1}')}"
JENKINS_URL="${JENKINS_URL:-http://$VM_IP:$JENKINS_PORT/}"

# api METHODE /chemin [options curl...]  -> corps JSON sur stdout, échec si HTTP >= 400
api() {
  local method=$1 path=$2; shift 2
  curl -sS --fail-with-body -X "$method" -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$API$path" "$@"
}
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }
log() { printf '\033[1;33m==> %s\033[0m\n' "$*" >&2; }

# Suppression immédiate d'un projet. Depuis GitLab 18, la suppression est différée (30 j) aussi en CE :
# le 1er DELETE marque le projet (renommé ...-deletion_scheduled-<id>), le 2nd avec permanently_remove
# et full_path le supprime réellement.
delete_project_now() {
  local id=$1 path
  api DELETE "/projects/$id" >/dev/null 2>&1 || true
  path=$(api GET "/projects/$id" 2>/dev/null | jq -r .path_with_namespace) || return 0
  api DELETE "/projects/$id?permanently_remove=true&full_path=$(urlenc "$path")" >/dev/null
}
