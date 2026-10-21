#!/usr/bin/env bash
# Module 8 — Réduction effective d'un dépôt GitLab dont l'historique contient de gros
# fichiers supprimés (correction du TP 08, partie A). Étapes :
#   1. mesure « avant » (API + disque) ;
#   2. clone nu (--bare) et analyse des plus gros blobs ;
#   3. git filter-repo (par défaut : retire les blobs > 10 Mo ; ou FILTRE="--path-glob '*.dump' --invert-paths") ;
#   4. autorise temporairement le push forcé sur les branches protégées, pousse
#      refs/heads/* et refs/tags/* en force, rétablit la protection ;
#   5. envoie filter-repo/commit-map à « Repository cleanup » (nettoyage-depot-gitlab.sh) :
#      GitLab supprime ses références internes vers les anciens commits ;
#   6. housekeeping « eager » puis « prune », mesure « après ».
# Usage : ./reduire-depot.sh [groupe/projet=sandbox/depot-volumineux] [seuil=10M]
set -euo pipefail
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
HOTE=gitlab.formation.lan; API=http://$HOTE/api/v4
PROJET=${1:-sandbox/depot-volumineux}; SEUIL=${2:-10M}
DIR=$(dirname "$(readlink -f "$0")")
TRAVAIL=${TRAVAIL:-$HOME/m08-travail}
enc() { jq -rn --arg v "$1" '$v|@uri'; }
api() { local m=$1 p=$2; shift 2; curl -sSf -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "$API$p" "$@"; }
t() { printf '\n===== %s =====\n' "$*"; }
id=$(api GET "/projects/$(enc "$PROJET")" | jq -r .id)
mesure() {
  api GET "/projects/$id?statistics=true" | jq -r '"API : dépôt \(.statistics.repository_size) octets, \(.statistics.commit_count) commits"'
}

t "1. Avant"
mesure
t "2. Clone nu et analyse"
mkdir -p "$TRAVAIL"; rm -rf "$TRAVAIL/${PROJET##*/}.git"
git clone -q --bare "http://oauth2:$TOKEN@$HOTE/$PROJET.git" "$TRAVAIL/${PROJET##*/}.git"
cd "$TRAVAIL/${PROJET##*/}.git"
git count-objects -vH | grep size-pack
"$DIR/gros-blobs.sh" . 5
t "3. git filter-repo --strip-blobs-bigger-than $SEUIL"
git filter-repo --strip-blobs-bigger-than "$SEUIL" --force
git count-objects -vH | grep size-pack
echo "commit-map : $(($(wc -l < filter-repo/commit-map) - 1)) commits réécrits"
t "4. Push forcé (protection levée le temps du push)"
git remote get-url origin >/dev/null 2>&1 || git remote add origin "http://oauth2:$TOKEN@$HOTE/$PROJET.git"
git config --unset remote.origin.mirror || true
proteges=$(api GET "/projects/$id/protected_branches" | jq -r '.[] | select(.allow_force_push == false) | .name')
for b in $proteges; do api PATCH "/projects/$id/protected_branches/$(enc "$b")?allow_force_push=true" >/dev/null; done
git push --force origin 'refs/heads/*'
git push --force origin 'refs/tags/*'
for b in $proteges; do api PATCH "/projects/$id/protected_branches/$(enc "$b")?allow_force_push=false" >/dev/null; done
echo "protection rétablie sur : ${proteges:-aucune}"
t "5. Repository cleanup (commit-map)"
"$DIR/nettoyage-depot-gitlab.sh" "$PROJET" filter-repo/commit-map
sleep 30
t "6. Housekeeping et mesure après"
api POST "/projects/$id/housekeeping?task=eager" >/dev/null; sleep 20
api POST "/projects/$id/housekeeping?task=prune" >/dev/null; sleep 20
mesure
echo "Côté disque : sudo ./diagnostic-depot.sh $PROJET"
