#!/usr/bin/env bash
# =============================================================================
# Module 04 - Démo « Comptes de service et jetons GitLab » (GitLab CE 19.4.2)
#  1. compte de service d'instance (API /service_accounts, disponible en CE 19.x,
#     100 comptes maximum en édition gratuite) + PAT de ce compte
#  2. jetons de projet et de groupe (comptes bot), jeton de déploiement,
#     jeton de déclenchement de pipeline, jeton de runner -> préfixes
#  3. identification d'un jeton quelconque : POST /admin/token
#  4. rotation (admin, puis auto-rotation avec le scope self_rotate)
#  5. détection de réutilisation : un jeton déjà « tourné » présenté à /rotate
#     révoque TOUTE la famille de jetons
#  6. révocation
#
# Objets créés : groupe m04-tests, projet m04-tests/m04-demo-jetons, compte de service
# m04-svc-demo (supprimés par nettoyage-m04.sh). Relançable.
# =============================================================================
set -Eeuo pipefail

API=${GITLAB_URL:-http://gitlab.formation.lan}/api/v4
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
api() { local m=$1 p=$2; shift 2; curl -sS --fail-with-body -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "$API$p" "$@"; }
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }
log() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
in_days() { date -d "+$1 days" +%F; }
mask() { sed -E 's/(gl[a-z]+-.{4})[A-Za-z0-9_.-]+/\1…/g'; }   # n'affiche que le début des jetons
code() { curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $1" "$API/${2:-user}"; }

# ---------------------------------------------------------------------------
log "0. Groupe m04-tests et projet m04-demo-jetons"
GID=$(api GET /groups/m04-tests 2>/dev/null | jq -r .id) || \
  GID=$(api POST /groups --data name=m04-tests --data path=m04-tests --data visibility=private | jq -r .id)
PID=$(api GET "/projects/$(urlenc m04-tests/m04-demo-jetons)" 2>/dev/null | jq -r .id) || \
  PID=$(api POST /projects --data namespace_id="$GID" --data path=m04-demo-jetons \
        --data initialize_with_readme=true | jq -r .id)
echo "groupe $GID, projet $PID"

log "1. Compte de service d'instance + jeton personnel"
SA=$(api GET "/users?username=m04-svc-demo" | jq -r '.[0].id // empty')
[[ -n $SA ]] || SA=$(api POST /service_accounts --data name="Service démo m04" --data username=m04-svc-demo | jq -r .id)
api GET "/service_accounts" | jq -c '.[] | select(.username=="m04-svc-demo") | {id,username,email}'
api GET "/users/$SA" | jq -c '{username,bot,external,state}'
SA_TOK=$(api POST "/users/$SA/personal_access_tokens" --data name=m04-pat-sa \
  --data "scopes[]=read_api" --data "scopes[]=self_rotate" --data "expires_at=$(in_days 30)" | jq -r .token)
echo "PAT du compte de service : $(mask <<<"$SA_TOK")"
# un compte de service n'occupe pas de licence et ne peut pas se connecter à l'UI ;
# on lui donne des droits comme à un utilisateur :
api POST "/projects/$PID/members" --data user_id="$SA" --data access_level=20 >/dev/null 2>&1 || true

log "2. Autres types de jetons (préfixes)"
PRJ=$(api POST "/projects/$PID/access_tokens" --data name=m04-prj --data "scopes[]=read_repository" \
      --data access_level=20 --data "expires_at=$(in_days 30)")
echo "jeton de projet   : $(jq -r .token <<<"$PRJ" | mask)  (bot user_id=$(jq -r .user_id <<<"$PRJ"))"
GRP=$(api POST "/groups/$GID/access_tokens" --data name=m04-grp --data "scopes[]=read_api" \
      --data access_level=10 --data "expires_at=$(in_days 30)")
echo "jeton de groupe   : $(jq -r .token <<<"$GRP" | mask)"
DT=$(api POST "/projects/$PID/deploy_tokens" --data name=m04-deploy --data "scopes[]=read_repository" \
     --data "expires_at=$(in_days 30)")
echo "jeton de déploiement : $(jq -r .token <<<"$DT" | mask)  username=$(jq -r .username <<<"$DT")"
TRG=$(api POST "/projects/$PID/triggers" --data description=m04-trigger)
echo "jeton de déclenchement : $(jq -r .token <<<"$TRG" | mask)"
RUN=$(api POST /user/runners --data runner_type=project_type --data project_id="$PID" --data description=m04-runner)
echo "jeton de runner   : $(jq -r .token <<<"$RUN" | mask)  expire : $(jq -r .token_expires_at <<<"$RUN")"

log "3. Identifier un jeton inconnu (POST /admin/token, admin)"
for t in "$SA_TOK" "$(jq -r .token <<<"$PRJ")" "$(jq -r .token <<<"$DT")" "$(jq -r .token <<<"$RUN")"; do
  printf '%s -> ' "$(mask <<<"$t")"
  curl -s -X POST -H "PRIVATE-TOKEN: $TOKEN" "$API/admin/token" --data-urlencode "token=$t" \
    | jq -c '{id,name,user_id,scopes,expires_at,description}|with_entries(select(.value!=null))'
done

log "4a. Rotation par un administrateur (sans expires_at : +7 jours !)"
PRJ_ID=$(jq -r .id <<<"$PRJ")
api POST "/projects/$PID/access_tokens/$PRJ_ID/rotate" | jq -c '{id,name,expires_at}'
log "4b. Auto-rotation du PAT du compte de service (scope self_rotate)"
R1=$(curl -s -X POST -H "PRIVATE-TOKEN: $SA_TOK" "$API/personal_access_tokens/self/rotate" --data "expires_at=$(in_days 30)")
jq -c '{id,name,expires_at}' <<<"$R1"; SA_TOK2=$(jq -r .token <<<"$R1")
echo "ancien jeton -> HTTP $(code "$SA_TOK") ; nouveau -> HTTP $(code "$SA_TOK2" "projects/$PID")"

log "5. Réutilisation d'un jeton déjà tourné sur /rotate => révocation de la famille"
curl -s -X POST -H "PRIVATE-TOKEN: $SA_TOK" "$API/personal_access_tokens/self/rotate"; echo
echo "nouveau jeton (pourtant jamais divulgué) -> HTTP $(code "$SA_TOK2" "projects/$PID")"
api GET "/personal_access_tokens?user_id=$SA" | jq -c '.[] | {id,name,active,revoked}'

log "6. Révocation"
api DELETE "/projects/$PID/access_tokens/$(api GET "/projects/$PID/access_tokens?state=active" | jq -r '.[0].id')"
api DELETE "/groups/$GID/access_tokens/$(jq -r .id <<<"$GRP")"
api DELETE "/projects/$PID/deploy_tokens/$(jq -r .id <<<"$DT")"
api DELETE "/projects/$PID/triggers/$(jq -r .id <<<"$TRG")"
api DELETE "/runners/$(jq -r .id <<<"$RUN")"
echo "jeton de projet, de groupe, de déploiement, de déclenchement et runner révoqués/supprimés"
