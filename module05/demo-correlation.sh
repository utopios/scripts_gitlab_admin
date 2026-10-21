#!/usr/bin/env bash
# Module 5 — Démo : une requête API, son X-Request-Id, et sa trace dans tous les journaux.
# Crée un projet m05-demo-correlation (avec README), suit sa création dans Workhorse,
# Rails, Gitaly et Sidekiq, puis supprime le projet. Relançable.
set -euo pipefail
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
API=http://gitlab.formation.lan/api/v4
DIR=$(dirname "$(readlink -f "$0")")

# Suppression DÉFINITIVE d'un projet : depuis GitLab 18, DELETE ne fait que « marquer pour
# suppression » (renommage en …-deletion_scheduled-<id>, purge après deletion_adjourned_period
# jours) ; un 2e appel avec permanently_remove=true et full_path supprime immédiatement.
supprimer() {
  local id=$1 chemin
  curl -s -o /dev/null -H "PRIVATE-TOKEN: $TOKEN" -X DELETE "$API/projects/$id"
  sleep 2
  chemin=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" "$API/projects/$id" | jq -r '.path_with_namespace // empty')
  [[ -n $chemin ]] && curl -s -o /dev/null -H "PRIVATE-TOKEN: $TOKEN" -X DELETE \
    "$API/projects/$id?permanently_remove=true&full_path=$(jq -rn --arg v "$chemin" '$v|@uri')"
  return 0
}

# Nettoyage d'une exécution précédente
old=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" "$API/projects/root%2Fm05-demo-correlation" | jq -r '.id // empty')
[[ -n $old ]] && supprimer "$old" && sleep 5

entetes=$(mktemp)
curl -s -D "$entetes" -o /dev/null -H "PRIVATE-TOKEN: $TOKEN" -X POST "$API/projects" \
  --data name=m05-demo-correlation --data initialize_with_readme=true
cid=$(awk 'tolower($1) == "x-request-id:" {print $2}' "$entetes" | tr -d '\r')
rm -f "$entetes"
echo "X-Request-Id renvoyé par GitLab : $cid"
echo "(attente 10 s : les tâches Sidekiq s'exécutent de façon asynchrone)"
sleep 10
"$DIR/correler.sh" "$cid"

id=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" "$API/projects/root%2Fm05-demo-correlation" | jq -r .id)
supprimer "$id"
echo; echo "Projet de démonstration supprimé (id $id)."
