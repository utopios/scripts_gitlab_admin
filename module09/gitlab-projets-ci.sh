#!/usr/bin/env bash
# Crée dans le groupe m09-ci les projets construits par Jenkins, avec le contenu de app-exemple/ :
#   m09-ci/app-jenkins      -> déclenché par un WEBHOOK de projet (jeton secret X-Gitlab-Token)
#   m09-ci/app-integration  -> déclenché par l'INTÉGRATION Jenkins native de GitLab (CE)
# Paramètre optionnel : liste des projets à créer (défaut : les deux).
# Relançable : un projet existant n'est pas modifié.
source "$(dirname "$0")/lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
GROUP=m09-ci
gid=$(api GET "/groups/$GROUP" | jq -r .id)

for name in "${@:-app-jenkins app-integration}"; do for p in $name; do
  if pid=$(api GET "/projects/$(urlenc "$GROUP/$p")" 2>/dev/null | jq -r .id); then
    echo "projet $GROUP/$p existe déjà (id=$pid)"; continue
  fi
  log "Création de $GROUP/$p"
  pid=$(api POST /projects --data "name=$p" --data "namespace_id=$gid" --data "visibility=private" \
        --data "default_branch=main" --data "initialize_with_readme=false" \
        --data "only_allow_merge_if_pipeline_succeeds=true" | jq -r .id)
  # Premier commit : tous les fichiers de app-exemple/ (scripts .sh rendus exécutables)
  actions=$(cd "$HERE/app-exemple" && for f in *; do
    jq -n --arg f "$f" --rawfile c "$f" '{action:"create", file_path:$f, content:$c}
      + (if ($f|endswith(".sh")) then {execute_filemode:true} else {} end)'
  done | jq -s .)
  jq -n --argjson a "$actions" '{branch:"main", commit_message:"Application exemple construite par Jenkins", actions:$a}' \
    | api POST "/projects/$pid/repository/commits" -H 'Content-Type: application/json' --data @- \
    | jq -r '"commit initial " + .short_id'
  echo "projet $GROUP/$p : id=$pid"
done; done
