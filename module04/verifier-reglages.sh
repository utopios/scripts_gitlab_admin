#!/usr/bin/env bash
# =============================================================================
# Module 04 - TP étape 6 : appliquer les réglages d'instance et VÉRIFIER leurs effets
#   1. prépare m04-admin (admin, 2 jetons : api seul / api+admin_mode) et m04-dev
#      (clé RSA 2048 déposée AVANT la restriction)
#   2. reglages-instance.sh appliquer
#   3. contrôles : admin mode, nouvelle clé RSA 2048, ancienne clé RSA 2048 en SSH,
#      PAT sans date d'expiration
#   4. reglages-instance.sh restaurer   (toujours exécuté, même en cas d'erreur)
# Exécuter sur le serveur GitLab. Objets créés : m04-admin, m04-dev (nettoyage-m04.sh).
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")"
GITLAB_HOST=${GITLAB_HOST:-gitlab.formation.lan}
API="http://$GITLAB_HOST/api/v4"
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
DIR=~/m04-cles; mkdir -p "$DIR"; chmod 700 "$DIR"
api() { local m=$1 p=$2; shift 2; curl -sS -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "$API$p" "$@"; }
code() { curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $1" "$API$2"; }
log() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
user() {   # user <username> [admin]
  local id; id=$(api GET "/users?username=$1" | jq -r '.[0].id // empty')
  [[ -n $id ]] || id=$(api POST /users --data "username=$1" --data "name=$1" --data "email=$1@formation.lan" \
    --data skip_confirmation=true --data "admin=${2:-false}" --data-urlencode "password=$(openssl rand -base64 18)" | jq -r .id)
  echo "$id"
}

log "1. Préparation (avant application de la politique)"
ADM=$(user m04-admin true); DEV=$(user m04-dev)
TK_API=$(api POST "/users/$ADM/personal_access_tokens" --data name=m04-api-seul --data "scopes[]=api" \
  --data "expires_at=$(date -d +2days +%F)" | jq -r .token)
TK_AM=$(api POST "/users/$ADM/personal_access_tokens" --data name=m04-api-adminmode --data "scopes[]=api" \
  --data "scopes[]=admin_mode" --data "expires_at=$(date -d +2days +%F)" | jq -r .token)
[[ -f $DIR/rsa2048 ]] || ssh-keygen -q -t rsa -b 2048 -N '' -C m04-dev@rsa2048 -f "$DIR/rsa2048"
rm -f "$DIR/rsa2048-bis"*; ssh-keygen -q -t rsa -b 2048 -N '' -C m04-dev@rsa2048-bis -f "$DIR/rsa2048-bis"
for k in $(api GET "/users/$DEV/keys" | jq -r '.[]|select(.title=="m04-rsa2048-bis").id'); do api DELETE "/users/$DEV/keys/$k"; done
api GET "/users/$DEV/keys" | jq -e '.[]|select(.title=="m04-rsa2048")' >/dev/null || \
  api POST "/users/$DEV/keys" --data title=m04-rsa2048 --data-urlencode "key=$(cat "$DIR/rsa2048.pub")" \
    --data "expires_at=$(date -d +30days +%F)" | jq -c '{id,title}'
echo "m04-admin=$ADM, m04-dev=$DEV ; jeton api seul -> /application/settings : HTTP $(code "$TK_API" /application/settings)"

trap './reglages-instance.sh restaurer >/dev/null && echo "(réglages restaurés)"' EXIT
log "2. Application de la politique"
./reglages-instance.sh appliquer | jq -c .
# Les réglages sont mis en cache dans chaque processus Puma/Sidekiq pendant 60 s
# (gitlab_rails['application_settings_cache_seconds']) : sans attente, le résultat
# dépend du worker Puma qui traite la requête.
echo "attente 65 s (cache des réglages d'application)"; sleep 65

log "3. Contrôles"
echo "admin mode : jeton api seul -> HTTP $(code "$TK_API" /application/settings) ; api+admin_mode -> HTTP $(code "$TK_AM" /application/settings)"
echo -n "nouvelle clé RSA 2048 : "
api POST "/users/$DEV/keys" --data title=m04-rsa2048-bis --data-urlencode "key=$(cat "$DIR/rsa2048-bis.pub")" | jq -c .
echo -n "ancienne clé RSA 2048 (ssh -T) : "
ssh -i "$DIR/rsa2048" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -T "git@$GITLAB_HOST" 2>&1
echo -n "PAT sans expires_at : "
api POST "/users/$DEV/personal_access_tokens" --data name=m04-sans-date --data "scopes[]=read_api" | jq -c '{name,expires_at}'

log "4. Restauration"
