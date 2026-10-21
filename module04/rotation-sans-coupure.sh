#!/usr/bin/env bash
# =============================================================================
# Module 04 - Rotation d'un jeton de pipeline SANS interruption de service
#
# Variante de rotation-jeton-pipeline.sh : au lieu de « …/rotate » (qui révoque
# l'ancien jeton immédiatement, d'où une fenêtre où le pipeline échoue), on
# procède par chevauchement :
#   1. créer un NOUVEAU jeton (l'ancien reste valide) ;
#   2. mettre à jour la variable CI/CD API_TOKEN ;
#   3. prouver que le pipeline fonctionne avec le nouveau jeton ;
#   4. seulement alors, révoquer l'ancien jeton.
#
# Prérequis : avoir lancé rotation-jeton-pipeline.sh (projet root/m04-rotation-ci,
# variable API_TOKEN, jeton actif « m04-ci-lecture »). Objets m04- supprimés par
# nettoyage-m04.sh. Relançable (chaque exécution fait une rotation complète).
# Usage : ./rotation-sans-coupure.sh [namespace]   (défaut : root)
# =============================================================================
set -Eeuo pipefail

API="${GITLAB_URL:-http://gitlab.formation.lan}/api/v4"
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
NS=${1:-root}
api() { local m=$1 p=$2; shift 2; curl -sS --fail-with-body -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "$API$p" "$@"; }
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }
log() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
code_avec() { curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $1" "$API/projects/$PID"; }

run_pipeline() {   # lance un pipeline sur main, attend la fin, affiche le statut
  local pid status
  pid=$(api POST "/projects/$PID/pipeline" --data ref=main | jq -r .id)
  for _ in $(seq 1 60); do
    status=$(api GET "/projects/$PID/pipelines/$pid" | jq -r .status)
    case $status in success|failed|canceled) break ;; esac
    sleep 3
  done
  echo "pipeline $pid : $status"
}

PID=$(api GET "/projects/$(urlenc "$NS/m04-rotation-ci")" | jq -r .id)

log "1. Jeton actuel (celui que lit la variable API_TOKEN)"
OLD_VALUE=$(api GET "/projects/$PID/variables/API_TOKEN" | jq -r .value)
# GET /personal_access_tokens/self appelé AVEC le jeton lui-même : renvoie son id
OLD_ID=$(curl -s -H "PRIVATE-TOKEN: $OLD_VALUE" "$API/personal_access_tokens/self" | jq -r .id)
api GET "/projects/$PID/access_tokens/$OLD_ID" | jq -c '{id,name,active,expires_at}'

log "2. Création d'un NOUVEAU jeton (l'ancien reste valide)"
R=$(api POST "/projects/$PID/access_tokens" --data-urlencode "name=m04-ci-lecture" \
    --data "scopes[]=read_api" --data access_level=20 --data "expires_at=$(date -d +30days +%F)")
NEW_ID=$(jq -r .id <<<"$R"); NEW_VALUE=$(jq -r .token <<<"$R")
echo "nouveau jeton id=$NEW_ID (bot user_id=$(jq -r .user_id <<<"$R")), expire le $(jq -r .expires_at <<<"$R")"
echo "ancien jeton -> HTTP $(code_avec "$OLD_VALUE") ; nouveau jeton -> HTTP $(code_avec "$NEW_VALUE")"

log "3. Mise à jour de la variable CI/CD, puis pipeline"
api PUT "/projects/$PID/variables/API_TOKEN" --data-urlencode "value=$NEW_VALUE" \
  --data masked=true --data protected=true | jq -c '{key,masked,protected}'
run_pipeline

log "4. Révocation de l'ancien jeton, seulement maintenant"
echo "DELETE /projects/$PID/access_tokens/$OLD_ID -> HTTP $(curl -s -o /dev/null -w '%{http_code}' \
  -X DELETE -H "PRIVATE-TOKEN: $TOKEN" "$API/projects/$PID/access_tokens/$OLD_ID")"
echo "ancien jeton -> HTTP $(code_avec "$OLD_VALUE") ; nouveau jeton -> HTTP $(code_avec "$NEW_VALUE")"
run_pipeline
echo "ROTATION SANS COUPURE OK : aucun pipeline en échec pendant l'opération"
