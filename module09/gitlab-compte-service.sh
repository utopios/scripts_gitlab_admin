#!/usr/bin/env bash
# Crée le compte de service GitLab utilisé par Jenkins + ses deux jetons à scopes minimaux.
#   - utilisateur local m09-svc-jenkins (un compte de service /service_accounts, disponible en CE 19.4.2,
#     conviendrait aussi : voir module 4)
#   - groupe m09-ci : le compte y est Maintainer. Developer suffit pour publier un statut sur une
#     branche NON protégée, mais GitLab répond 403 sur une branche protégée (main) si le compte ne peut
#     ni pousser ni merger dessus (constaté en 19.4.2). En CE, autoriser un utilisateur précis sur une
#     branche protégée est Premium : on donne donc Maintainer, limité au seul groupe des projets Jenkins.
#   - jeton "jenkins-statuts"  scope api             -> POST /projects/:id/statuses/:sha
#   - jeton "jenkins-clone"    scope read_repository -> git clone HTTP
# Les jetons sont écrits dans $SECRETS (chmod 600), jamais affichés.
# Relançable : ne recrée ni l'utilisateur, ni le groupe, ni des jetons déjà présents dans $SECRETS.
source "$(dirname "$0")/lib.sh"
SVC=m09-svc-jenkins
GROUP=m09-ci
EXPIRES=$(date -d '+90 days' +%F)          # rotation trimestrielle (cf. module 4)
mkdir -p "$SECRETS"; chmod 700 "$M09_DIR" "$SECRETS"

uid=$(api GET "/users?username=$SVC" | jq -r '.[0].id // empty')
if [[ -z $uid ]]; then
  log "Création de l'utilisateur $SVC"
  uid=$(api POST /users --data-urlencode "username=$SVC" --data-urlencode "name=Service Jenkins (CI)" \
        --data-urlencode "email=$SVC@formation.lan" --data "skip_confirmation=true" \
        --data "force_random_password=true" --data "projects_limit=0" --data "can_create_group=false" \
        --data-urlencode "note=Compte technique Jenkins - propriétaire : équipe plateforme - module 09" | jq -r .id)
fi
echo "utilisateur $SVC : id=$uid"

gid=$(api GET "/groups/$GROUP" 2>/dev/null | jq -r '.id // empty' || true)
if [[ -z $gid ]]; then
  log "Création du groupe $GROUP"
  gid=$(api POST /groups --data "name=$GROUP" --data "path=$GROUP" --data "visibility=private" | jq -r .id)
fi
echo "groupe $GROUP : id=$gid"
ROLE=${SVC_ROLE:-40}   # 40 = Maintainer (voir en-tête) ; SVC_ROLE=30 pour constater le 403 sur main
api POST "/groups/$gid/members" --data "user_id=$uid" --data "access_level=$ROLE" >/dev/null 2>&1 \
  || api PUT "/groups/$gid/members/$uid" --data "access_level=$ROLE" >/dev/null
echo "membre $SVC de $GROUP : access_level=$ROLE"

new_token() {   # new_token <nom> <scope> <fichier>
  local name=$1 scope=$2 file=$3
  if [[ -s $SECRETS/$file ]]; then echo "jeton $name : déjà présent dans $SECRETS/$file"; return; fi
  api POST "/users/$uid/personal_access_tokens" --data-urlencode "name=$name" \
      --data "scopes[]=$scope" --data "expires_at=$EXPIRES" | jq -j .token > "$SECRETS/$file"   # sans saut de ligne final
  chmod 600 "$SECRETS/$file"
  echo "jeton $name ($scope, expire $EXPIRES) -> $SECRETS/$file"
}
new_token jenkins-statuts api gitlab-api-token
new_token jenkins-clone read_repository gitlab-clone-token

ls -l "$SECRETS"
