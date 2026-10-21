#!/usr/bin/env bash
# Vérifie la chaîne GitLab -> Jenkins -> GitLab de bout en bout.
#   ./verif-bout-en-bout.sh <projet> push        commit sur main, attend les statuts Jenkins du commit
#   ./verif-bout-en-bout.sh <projet> mr          branche + merge request, attend le statut dans la MR
#   VERSION_CONTENU=casse ./verif-bout-en-bout.sh <projet> mr   -> statut failed attendu
# Code retour 0 si tous les statuts publiés sont "success".
source "$(dirname "$0")/lib.sh"
PROJ=${1:-m09-ci/app-jenkins}; MODE=${2:-push}
CONTENU=${VERSION_CONTENU:-"1.0.$(date +%s)"}
pid=$(api GET "/projects/$(urlenc "$PROJ")" | jq -r .id)
TS=$(date +%H%M%S)

commit() {   # commit <branche> <message> -> sha
  jq -n --arg b "$1" --arg m "$2" --arg c "$CONTENU"$'\n' \
     '{branch:$b, commit_message:$m, actions:[{action:"update", file_path:"VERSION", content:$c}]}' \
  | api POST "/projects/$pid/repository/commits" -H 'Content-Type: application/json' --data @- | jq -r .id
}

if [[ $MODE == mr ]]; then
  BR="m09-feature-$TS"
  api POST "/projects/$pid/repository/branches?branch=$BR&ref=main" >/dev/null
  sha=$(commit "$BR" "VERSION $CONTENU (branche $BR)")
  iid=$(api POST "/projects/$pid/merge_requests" --data "source_branch=$BR" --data "target_branch=main" \
        --data-urlencode "title=m09 : test Jenkins ($BR)" --data "remove_source_branch=true" | jq -r .iid)
  echo "MR !$iid ouverte ($BR, commit ${sha:0:8})"
else
  sha=$(commit main "VERSION $CONTENU")
  echo "commit ${sha:0:8} poussé sur main"
fi

log "Attente des statuts de commit publiés par Jenkins (max 3 min)"
for i in $(seq 1 36); do
  st=$(api GET "/projects/$pid/repository/commits/$sha/statuses")
  n=$(jq 'length' <<<"$st"); fini=$(jq '[.[] | select(.status=="success" or .status=="failed" or .status=="canceled")] | length' <<<"$st")
  [[ $n -ge 2 && $n -eq $fini ]] && break
  sleep 5
done
echo "GET /projects/$pid/repository/commits/${sha:0:8}…/statuses"
jq -r '.[] | [.name, .status, .ref, .author.username, .target_url] | @tsv' <<<"$st" | column -t

if [[ $MODE == mr ]]; then
  sleep 2
  log "Vue merge request (pipeline externe)"
  api GET "/projects/$pid/merge_requests/$iid" \
    | jq -c '{iid, merge_status: .detailed_merge_status, head_pipeline: (.head_pipeline | {id, source, status, sha: .sha[0:8]})}'
  api GET "/projects/$pid/merge_requests/$iid/pipelines" | jq -c '.[] | {id, source, status, ref}'
fi
jq -e 'length > 0 and all(.[]; .status == "success")' <<<"$st" >/dev/null
