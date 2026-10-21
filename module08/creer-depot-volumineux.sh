#!/usr/bin/env bash
# Module 8 — (Re)crée un dépôt « alourdi » équivalent à sandbox/depot-volumineux :
# 4 fichiers binaires de 20 Mo ajoutés puis supprimés (toujours dans l'historique),
# puis 50 petits commits. Sert à refaire les exercices de réduction autant de fois que
# nécessaire sans toucher au projet du seed.
# Usage : ./creer-depot-volumineux.sh [groupe/projet]   (défaut : sandbox/m08-volumineux)
# Si le projet existe déjà, il est supprimé définitivement puis recréé.
set -euo pipefail
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
HOTE=gitlab.formation.lan; API=http://$HOTE/api/v4
CIBLE=${1:-sandbox/m08-volumineux}
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
  --data visibility=internal | jq -r .id)

d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
git init -q -b main "$d"
c() { git -C "$d" add -A; git -C "$d" -c user.name="Bob Durand" -c user.email=bob.durand@formation.lan commit -q -m "$1"; }
echo "# ${CIBLE##*/}" > "$d/README.md"; c "Initialisation"
for i in 1 2 3 4; do
  dd if=/dev/urandom of="$d/export-$i.dump" bs=1M count=20 status=none; c "Ajout de l'export $i"
done
git -C "$d" rm -q 'export-*.dump'; c "Suppression des exports"
for i in $(seq 1 50); do echo "ligne $i" >> "$d/journal.txt"; c "Mise a jour du journal $i"; done
git -C "$d" push -q "http://oauth2:$TOKEN@$HOTE/$CIBLE.git" main
echo "Projet $CIBLE (id $id) créé : $(git -C "$d" rev-list --count main) commits, $(du -sh "$d/.git" | cut -f1) dans .git"
