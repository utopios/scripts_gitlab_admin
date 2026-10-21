#!/usr/bin/env bash
# =============================================================================
# Module 04 - TP « Audit des accès » - secret commité dans l'historique Git
#
# Ordre IMPÉRATIF : 1) détecter  2) RÉVOQUER/faire tourner le secret  3) réécrire
# l'historique  4) purger côté serveur (blobs + housekeeping)  5) prévenir les clones.
# Réécrire sans révoquer ne sert à rien : le secret a pu être cloné, mis en cache,
# copié dans une MR, un artefact, un fork...
#
# Le script travaille sur une COPIE : <namespace>/m04-infra-scripts (copie miroir de
# ops/infra-scripts). Pour rendre l'exercice réaliste, il ajoute dans la copie un VRAI
# jeton (jeton personnel d'un compte de service m04-fuite) commité puis « supprimé ».
#
# Usage : ./secret-historique.sh [namespace] [mode]
#   namespace : défaut root
#   mode      : filter-repo (défaut) = réécriture locale + push forcé + purge serveur
#               serveur              = réécriture côté serveur uniquement (« Remove blobs »)
# Prérequis : jeton admin (~/.gitlab-token ou $GITLAB_TOKEN), git, git-filter-repo, jq.
# Relançable : la copie est recréée à chaque exécution.
# =============================================================================
set -Eeuo pipefail

GITLAB_HOST=${GITLAB_HOST:-gitlab.formation.lan}
API="http://$GITLAB_HOST/api/v4"
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
NS=${1:-root}
MODE=${2:-filter-repo}
SRC=ops/infra-scripts
DST="$NS/m04-infra-scripts"
WORK=$(mktemp -d /tmp/m04-secret.XXXX)
trap 'rm -rf "$WORK"' EXIT
# Identifiants Git passés par en-tête HTTP (pas dans l'URL ni dans .git/config)
AUTH=(-c "http.extraHeader=Authorization: Basic $(printf 'oauth2:%s' "$TOKEN" | base64 -w0)")

api() { local m=$1 p=$2; shift 2; curl -sS --fail-with-body -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "$API$p" "$@"; }
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }
log() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
gql() { curl -sS --fail-with-body -X POST -H "PRIVATE-TOKEN: $TOKEN" "http://$GITLAB_HOST/api/graphql" -H 'Content-Type: application/json' --data "$1"; }

# ---------------------------------------------------------------------------
log "0. Préparation de la copie $DST"
if OLD=$(api GET "/projects/$(urlenc "$DST")" 2>/dev/null | jq -r .id); then
  # suppression immédiate d'un projet existant (2 appels : marquage puis suppression définitive)
  # suppression différée (renommage en ...-deletion_scheduled-<id>), puis définitive :
  # permanently_remove exige le NOUVEAU chemin complet du projet
  api DELETE "/projects/$OLD" >/dev/null || true
  FP=$(api GET "/projects/$OLD" | jq -r .path_with_namespace)
  api DELETE "/projects/$OLD?permanently_remove=true&full_path=$(urlenc "$FP")" >/dev/null
  for _ in $(seq 1 30); do api GET "/projects/$OLD" >/dev/null 2>&1 || break; sleep 2; done
fi
NSID=$(api GET "/namespaces/$(urlenc "$NS")" | jq -r .id)
PID=$(api POST /projects --data "namespace_id=$NSID" --data path=m04-infra-scripts \
      --data name=m04-infra-scripts --data visibility=private | jq -r .id)
git "${AUTH[@]}" clone -q --mirror "http://$GITLAB_HOST/$SRC.git" "$WORK/src.git"
git -C "$WORK/src.git" "${AUTH[@]}" push -q --mirror "http://$GITLAB_HOST/$DST.git"

# Fuite « réaliste » : un vrai jeton (compte de service m04-fuite) commité puis supprimé
SA=$(api GET "/users?username=m04-fuite" | jq -r '.[0].id // empty')
[[ -n $SA ]] || SA=$(api POST /service_accounts --data name=m04-fuite --data username=m04-fuite | jq -r .id)
LEAK=$(api POST "/users/$SA/personal_access_tokens" --data name=m04-jeton-fuite \
       --data "scopes[]=read_api" --data "expires_at=$(date -d +7days +%F)" | jq -r .token)
git "${AUTH[@]}" clone -q "http://$GITLAB_HOST/$DST.git" "$WORK/copie"
cd "$WORK/copie"
git config user.name farid.benali; git config user.email farid.benali@formation.lan
mkdir -p config && printf 'API_URL=%s\nGITLAB_TOKEN=%s\n' "$API" "$LEAK" > config/.env
git add config/.env && git commit -q -m "Ajout de la configuration API"
git rm -q config/.env && git commit -q -m "Oups, retrait du .env"
git "${AUTH[@]}" push -q origin main
echo "copie prête : projet $PID, $(git rev-list --count HEAD) commits"
cd "$WORK"

# ---------------------------------------------------------------------------
log "1. Détection dans TOUT l'historique (toutes les références)"
git "${AUTH[@]}" clone -q --mirror "http://$GITLAB_HOST/$DST.git" "$WORK/audit.git"
cd "$WORK/audit.git"
# git grep sur chaque commit : fichier + ligne, même si le fichier a été supprimé depuis
git rev-list --all | xargs git grep -n -I -E 'glpat-[0-9A-Za-z_.-]{20,}|PASSWORD=' \
  | sed -E 's/(glpat-.{6})[^ ]*/\1…(masqué)/; s/(PASSWORD=.{3}).*/\1…(masqué)/' | sort -u -t: -k2,3
mapfile -t FOUND < <(git rev-list --all | xargs git grep -h -o -I -E 'glpat-[0-9A-Za-z_.-]{20,}' | sort -u)
# OID des blobs fautifs (nécessaires pour la purge côté serveur)
mapfile -t BLOBS < <(git rev-list --objects --all | awk '$2=="config/.env"{print $1}' | sort -u)
echo "jetons distincts trouvés : ${#FOUND[@]} ; blobs config/.env : ${BLOBS[*]}"
OLD_COMMITS=$(git log --all --format=%H -- config/.env | tr '\n' ' ')

# ---------------------------------------------------------------------------
log "2. RÉVOCATION avant toute réécriture (API /admin/token)"
for t in "${FOUND[@]}"; do
  info=$(curl -s -X POST -H "PRIVATE-TOKEN: $TOKEN" "$API/admin/token" --data-urlencode "token=$t")
  if jq -e .id >/dev/null 2>&1 <<<"$info"; then
    echo "${t:0:12}… = jeton #$(jq -r .id <<<"$info") « $(jq -r .name <<<"$info") » de l'utilisateur $(jq -r .user_id <<<"$info") -> révocation"
    code=$(curl -s -o "$WORK/rev.json" -w "%{http_code}" -X DELETE \
      -H "PRIVATE-TOKEN: $TOKEN" "$API/admin/token" --data-urlencode "token=$t")
    echo "  DELETE /admin/token -> HTTP $code $(cat "$WORK/rev.json")"
    if [[ $code != 204 ]]; then
      # 19.4.2 : /admin/token ne sait pas révoquer le jeton d'un COMPTE DE SERVICE
      # ("Unsupported personal access token type") -> révocation par l'id du jeton
      curl -s -o /dev/null -w "  DELETE /personal_access_tokens/$(jq -r .id <<<"$info") -> HTTP %{http_code}\n" \
        -X DELETE -H "PRIVATE-TOKEN: $TOKEN" "$API/personal_access_tokens/$(jq -r .id <<<"$info")"
    fi
    curl -s -o /dev/null -w "  contrôle : le jeton fuité -> HTTP %{http_code}\n" -H "PRIVATE-TOKEN: $t" "$API/user"
  else
    echo "${t:0:12}… inconnu de GitLab ($(jq -c . <<<"$info")) : faux jeton ou autre instance"
  fi
done
echo "DB_PASSWORD : à changer dans la base concernée (hors GitLab) AVANT la réécriture."

# ---------------------------------------------------------------------------
if [[ $MODE == filter-repo ]]; then
log "3. Réécriture de l'historique avec git filter-repo (sur un clone miroir frais)"
# --invert-paths : supprime le fichier de tout l'historique ; les commits devenus vides
# sont élagués. Variante : --replace-text expressions.txt pour masquer seulement la valeur.
git filter-repo --force --invert-paths --path config/.env
git log --oneline --all
test -z "$(git rev-list --all | xargs git grep -l -I 'glpat-' 2>/dev/null)" && echo "plus aucun glpat- dans l'historique local"

# ---------------------------------------------------------------------------
log "4. Push forcé (autorisation temporaire sur la branche protégée main)"
api PATCH "/projects/$PID/protected_branches/main?allow_force_push=true" | jq -c '{name,allow_force_push}'
git "${AUTH[@]}" push -q --force --mirror "http://$GITLAB_HOST/$DST.git" 2>&1 | grep -v 'refs/merge-requests\|refs/pipelines\|refs/keep-around' || true
api PATCH "/projects/$PID/protected_branches/main?allow_force_push=false" | jq -c '{name,allow_force_push}'

# ---------------------------------------------------------------------------
fi  # fin du mode filter-repo

log "5. Côté serveur, les anciens objets sont encore accessibles..."
for c in $OLD_COMMITS; do
  curl -s -o /dev/null -w "  commit ${c:0:8} -> HTTP %{http_code}\n" -H "PRIVATE-TOKEN: $TOKEN" "$API/projects/$PID/repository/commits/$c"
done
for b in "${BLOBS[@]}"; do
  curl -s -o /dev/null -w "  blob   ${b:0:8} -> HTTP %{http_code}\n" -H "PRIVATE-TOKEN: $TOKEN" "$API/projects/$PID/repository/blobs/$b/raw"
done

log "6. Purge des blobs côté serveur (GraphQL projectBlobsRemove = « Remove blobs » de l'UI)"
OIDS=$(printf '%s\n' "${BLOBS[@]}" | jq -R . | jq -sc .)
gql "$(jq -nc --arg p "$DST" --argjson o "$OIDS" \
  '{query:"mutation($p:ID!,$o:[String!]!){projectBlobsRemove(input:{projectPath:$p,blobOids:$o}){errors}}",variables:{p:$p,o:$o}}')" | jq -c .
sleep 15   # traitement asynchrone (Sidekiq : Repositories::RewriteHistoryWorker)
log "7. Housekeeping « prune » (objets inaccessibles ; délai de grâce Gitaly ~30 min)"
api POST "/projects/$PID/housekeeping?task=prune" >/dev/null && sleep 10
for c in $OLD_COMMITS; do
  curl -s -o /dev/null -w "  commit ${c:0:8} -> HTTP %{http_code}\n" -H "PRIVATE-TOKEN: $TOKEN" "$API/projects/$PID/repository/commits/$c"
done
for b in "${BLOBS[@]}"; do
  curl -s -o /dev/null -w "  blob   ${b:0:8} -> HTTP %{http_code}\n" -H "PRIVATE-TOKEN: $TOKEN" "$API/projects/$PID/repository/blobs/$b/raw"
done
api GET "/projects/$PID/repository/commits?all=true" | jq -r '.[] | "  \(.short_id) \(.title)"'
echo "Dernière étape (hors script) : prévenir les détenteurs de clones (re-cloner), vérifier forks, MR, artefacts."
