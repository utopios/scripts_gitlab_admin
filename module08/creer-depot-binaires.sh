#!/usr/bin/env bash
# Module 8 — Crée un projet dont les binaires ont été commités SANS Git LFS
# (images, archives, maquette PDF : 3 versions successives de chaque), pour l'exercice
# de migration vers LFS. Usage : ./creer-depot-binaires.sh [groupe/projet]
# (défaut : sandbox/assets-binaires). Un projet existant est supprimé définitivement.
set -euo pipefail
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
HOTE=gitlab.formation.lan; API=http://$HOTE/api/v4
CIBLE=${1:-sandbox/assets-binaires}
enc() { jq -rn --arg v "$1" '$v|@uri'; }
api() { local m=$1 p=$2; shift 2; curl -sS -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "$API$p" "$@"; }

id=$(api GET "/projects/$(enc "$CIBLE")" | jq -r '.id // empty')
if [[ -n $id ]]; then
  api DELETE "/projects/$id" >/dev/null; sleep 2
  chemin=$(api GET "/projects/$id" | jq -r '.path_with_namespace // empty')
  [[ -z $chemin ]] || api DELETE "/projects/$id?permanently_remove=true&full_path=$(enc "$chemin")" >/dev/null
  sleep 5
fi
ns=$(api GET "/namespaces/$(enc "${CIBLE%/*}")" | jq -r .id)
id=$(api POST /projects --data "namespace_id=$ns" --data "path=${CIBLE##*/}" --data "name=${CIBLE##*/}" \
  --data visibility=internal --data lfs_enabled=true | jq -r .id)

d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
git init -q -b main "$d"
c() { git -C "$d" add -A; git -C "$d" -c user.name="Emma Bernard" -c user.email=emma.bernard@formation.lan commit -q -m "$1"; }
mkdir -p "$d/assets/img" "$d/assets/livrables" "$d/src"
printf '# assets-binaires\nRessources graphiques et livrables du portail.\n' > "$d/README.md"
echo 'console.log("portail");' > "$d/src/app.js"
c "Initialisation"
for v in 1 2 3; do
  head -c $((3*1024*1024)) /dev/urandom > "$d/assets/img/banniere.png"
  head -c $((2*1024*1024)) /dev/urandom > "$d/assets/img/logo.png"
  head -c $((4*1024*1024)) /dev/urandom > "$d/assets/livrables/maquette.pdf"
  head -c $((5*1024*1024)) /dev/urandom > "$d/assets/livrables/export-$v.zip"
  echo "// version $v" >> "$d/src/app.js"
  c "Livraison des ressources v$v"
done
git -C "$d" push -q "http://oauth2:$TOKEN@$HOTE/$CIBLE.git" main
echo "Projet $CIBLE (id $id) : $(git -C "$d" rev-list --count main) commits, .git = $(du -sh "$d/.git" | cut -f1)"
