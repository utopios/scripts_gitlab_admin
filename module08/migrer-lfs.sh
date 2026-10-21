#!/usr/bin/env bash
# Module 8 — Migration de binaires existants vers Git LFS, historique compris
# (correction du TP 08, partie B).
#   1. clone, « git lfs migrate info » (quels types pèsent le plus) ;
#   2. « git lfs migrate import --everything --include=… --object-map=… » : réécrit tous les
#      commits, les binaires deviennent des pointeurs, .gitattributes est ajouté ;
#   3. push forcé (les objets LFS sont envoyés au serveur LFS de GitLab) ;
#   4. le fichier object-map (« ancien,nouveau ») converti au format commit-map
#      (« ancien nouveau ») est envoyé à Repository cleanup ;
#   5. housekeeping et mesures (repository_size / lfs_objects_size).
# Usage : ./migrer-lfs.sh [groupe/projet=sandbox/assets-binaires] [motifs="*.png,*.pdf,*.zip"]
set -euo pipefail
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
HOTE=gitlab.formation.lan; API=http://$HOTE/api/v4
PROJET=${1:-sandbox/assets-binaires}; MOTIFS=${2:-*.png,*.pdf,*.zip}
DIR=$(dirname "$(readlink -f "$0")")
TRAVAIL=${TRAVAIL:-$HOME/m08-travail}
enc() { jq -rn --arg v "$1" '$v|@uri'; }
api() { local m=$1 p=$2; shift 2; curl -sSf -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "$API$p" "$@"; }
t() { printf '\n===== %s =====\n' "$*"; }
id=$(api GET "/projects/$(enc "$PROJET")" | jq -r .id)
mesure() { api GET "/projects/$id?statistics=true" | jq -r '"API : dépôt \(.statistics.repository_size) octets, LFS \(.statistics.lfs_objects_size) octets"'; }

t "1. Avant"
mesure
mkdir -p "$TRAVAIL"; rm -rf "$TRAVAIL/${PROJET##*/}" "$TRAVAIL/${PROJET##*/}.object-map"
git clone -q "http://oauth2:$TOKEN@$HOTE/$PROJET.git" "$TRAVAIL/${PROJET##*/}"
cd "$TRAVAIL/${PROJET##*/}"
git config lfs.locksverify false   # évite le message (qui affiche l'URL avec le jeton)
git lfs migrate info --everything
t "2. Réécriture de l'historique"
git lfs migrate import --everything --include="$MOTIFS" --object-map="../${PROJET##*/}.object-map"
cat .gitattributes
git lfs ls-files
t "3. Push forcé"
proteges=$(api GET "/projects/$id/protected_branches" | jq -r '.[] | select(.allow_force_push == false) | .name')
for b in $proteges; do api PATCH "/projects/$id/protected_branches/$(enc "$b")?allow_force_push=true" >/dev/null; done
git push --force origin --all
git push --force origin --tags
for b in $proteges; do api PATCH "/projects/$id/protected_branches/$(enc "$b")?allow_force_push=false" >/dev/null; done
t "4. Repository cleanup"
tr ',' ' ' < "../${PROJET##*/}.object-map" > "../${PROJET##*/}.commit-map"
"$DIR/nettoyage-depot-gitlab.sh" "$PROJET" "../${PROJET##*/}.commit-map"
sleep 30
api POST "/projects/$id/housekeeping?task=eager" >/dev/null; sleep 20
t "5. Après"
mesure
