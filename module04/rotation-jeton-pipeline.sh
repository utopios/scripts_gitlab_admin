#!/usr/bin/env bash
# =============================================================================
# Module 04 - TP « Audit des accès » - étape « rotation d'un jeton de service »
#
# Scénario : un pipeline appelle l'API GitLab avec un jeton de PROJET stocké dans
# une variable CI/CD masquée et protégée (API_TOKEN). On fait tourner le jeton
# (rotation API), on met à jour la variable, et on PROUVE que :
#   1. le pipeline fonctionne avant la rotation ;
#   2. l'ancien jeton est refusé (401) après la rotation ;
#   3. le pipeline fonctionne après la rotation (nouvelle valeur de la variable).
#
# Objets créés (préfixe m04-, supprimés par nettoyage-m04.sh) :
#   projet  <namespace>/m04-rotation-ci, jeton de projet « m04-ci-lecture »,
#   variable CI/CD API_TOKEN.
#
# Usage : ./rotation-jeton-pipeline.sh [namespace]   (défaut : root)
# Prérequis : jeton administrateur dans ~/.gitlab-token ou $GITLAB_TOKEN, curl, jq,
#             runner d'instance avec le tag « shell ».
# Relançable : le projet et la variable sont réutilisés, un nouveau jeton est créé
#             si aucun jeton actif « m04-ci-lecture » n'existe.
# =============================================================================
set -Eeuo pipefail

GITLAB_URL=${GITLAB_URL:-http://gitlab.formation.lan}
API="$GITLAB_URL/api/v4"
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
NS=${1:-root}
PROJECT_PATH="$NS/m04-rotation-ci"
TOKEN_NAME="m04-ci-lecture"

api() {   # api METHODE /chemin [options curl...]
  local m=$1 p=$2; shift 2
  curl -sS --fail-with-body -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "$API$p" "$@"
}
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }
in_days() { date -d "+$1 days" +%F; }
log() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }

# Lance un pipeline sur main et attend sa fin ; affiche le statut et la trace du job
run_pipeline() {
  local pid id status job
  pid=$(api POST "/projects/$PID/pipeline" --data ref=main | jq -r .id)
  for _ in $(seq 1 60); do
    status=$(api GET "/projects/$PID/pipelines/$pid" | jq -r .status)
    case $status in success|failed|canceled) break ;; esac
    sleep 3
  done
  job=$(api GET "/projects/$PID/pipelines/$pid/jobs" | jq -r '.[0].id')
  echo "pipeline $pid : $status"
  # trace du job sans horodatage ni codes couleur
  api GET "/projects/$PID/jobs/$job/trace" | sed -E 's/\x1b\[[0-9;]*m//g; s/^[^ ]+ [0-9]+[OE]\+? ?//' \
    | grep -E '^(HTTP|Projet lu|ERROR|Job)' || true
  [[ $status == success ]]
}

# ---------------------------------------------------------------------------
log "1. Projet de test $PROJECT_PATH"
PID=$(api GET "/projects/$(urlenc "$PROJECT_PATH")" 2>/dev/null | jq -r .id) || PID=
if [[ -z $PID ]]; then
  NSID=$(api GET "/namespaces/$(urlenc "$NS")" | jq -r .id)
  PID=$(api POST /projects --data "namespace_id=$NSID" --data path=m04-rotation-ci \
        --data name=m04-rotation-ci --data visibility=private --data initialize_with_readme=true | jq -r .id)
  # Pipeline : lit le projet via l'API avec le jeton de la variable masquée
  CI=$(cat <<'EOF'
lecture-api:
  tags: [shell]
  script:
    - 'code=$(curl -s -o reponse.json -w "%{http_code}" -H "PRIVATE-TOKEN: $API_TOKEN" "$CI_API_V4_URL/projects/$CI_PROJECT_ID")'
    - echo "HTTP $code"
    - test "$code" = 200
    - 'echo "Projet lu : $(jq -r .path_with_namespace reponse.json)"'
EOF
)
  api POST "/projects/$PID/repository/files/.gitlab-ci.yml" --data branch=main \
    --data-urlencode "content=$CI" --data commit_message="Pipeline de test de rotation" >/dev/null
  echo "projet créé : id=$PID"
else
  echo "projet existant : id=$PID"
fi

# ---------------------------------------------------------------------------
log "2. Jeton de projet $TOKEN_NAME (read_api, Reporter, 30 jours)"
TID=$(api GET "/projects/$PID/access_tokens?state=active" | jq -r --arg n "$TOKEN_NAME" '[.[]|select(.name==$n)][0].id // empty')
if [[ -z $TID ]]; then
  R=$(api POST "/projects/$PID/access_tokens" --data-urlencode "name=$TOKEN_NAME" \
      --data "scopes[]=read_api" --data access_level=20 --data "expires_at=$(in_days 30)")
  TID=$(jq -r .id <<<"$R"); VALUE=$(jq -r .token <<<"$R")
  echo "jeton créé : id=$TID, expire le $(jq -r .expires_at <<<"$R")"
  # Variable masquée + protégée (main est protégée) ; on la recrée si besoin
  api DELETE "/projects/$PID/variables/API_TOKEN" >/dev/null 2>&1 || true
  api POST "/projects/$PID/variables" --data key=API_TOKEN --data-urlencode "value=$VALUE" \
    --data masked=true --data protected=true | jq -c '{key,masked,protected,hidden}'
else
  echo "jeton actif existant : id=$TID (on le fait tourner directement)"
  # Une variable masquée (non « hidden ») reste LISIBLE par l'API pour un Maintainer :
  VALUE=$(api GET "/projects/$PID/variables/API_TOKEN" | jq -r .value)
fi

# ---------------------------------------------------------------------------
log "3. Pipeline AVANT rotation"
run_pipeline

# ---------------------------------------------------------------------------
log "4. Rotation du jeton (nouvelle expiration : +30 jours)"
R=$(api POST "/projects/$PID/access_tokens/$TID/rotate" --data "expires_at=$(in_days 30)")
NEW_TID=$(jq -r .id <<<"$R"); NEW_VALUE=$(jq -r .token <<<"$R")
echo "ancien id=$TID -> nouvel id=$NEW_TID, expire le $(jq -r .expires_at <<<"$R")"
api GET "/projects/$PID/access_tokens/$TID" | jq -c '{id,name,active,revoked}'

if [[ -n $VALUE ]]; then
  log "5. L'ancien jeton est refusé"
  curl -s -o /dev/null -w "ancien jeton -> HTTP %{http_code}\n" -H "PRIVATE-TOKEN: $VALUE" "$API/projects/$PID"
fi

log "6. Pipeline avec l'ANCIENNE valeur de la variable : doit échouer"
run_pipeline && echo "ANOMALIE : le pipeline aurait dû échouer" || echo "échec attendu : la variable doit être mise à jour"

log "7. Mise à jour de la variable CI/CD API_TOKEN"
api PUT "/projects/$PID/variables/API_TOKEN" --data-urlencode "value=$NEW_VALUE" \
  --data masked=true --data protected=true | jq -c '{key,masked,protected}'

log "8. Pipeline APRÈS rotation et mise à jour de la variable"
run_pipeline && echo "ROTATION OK"
