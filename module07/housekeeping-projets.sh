#!/usr/bin/env bash
# Module 7 — Housekeeping ciblé : déclenche l'optimisation Gitaly des projets les plus
# volumineux (au-delà de SEUIL_MO), via l'API POST /projects/:id/housekeeping.
#   task=eager : repack complet (avec « cruft pack » pour les objets inaccessibles),
#                commit-graph, multi-pack-index, bitmaps ;
#   task=prune : supprime les objets inaccessibles depuis plus de 2 semaines (délai de
#                grâce) — à réserver aux dépôts qui ont été nettoyés.
# Usage : ./housekeeping-projets.sh [SEUIL_MO=10] [eager|prune]
set -euo pipefail
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token 2>/dev/null || cat /home/formateur/.gitlab-token)}
API=http://gitlab.formation.lan/api/v4
SEUIL=${1:-10}; TACHE=${2:-eager}

printf '%-45s %10s  %s\n' "PROJET" "DÉPÔT(Mo)" "HOUSEKEEPING"
page=1
while :; do
  lot=$(curl -sf -H "PRIVATE-TOKEN: $TOKEN" "$API/projects?statistics=true&per_page=100&page=$page&order_by=id&sort=asc")
  [[ $(jq length <<<"$lot") -eq 0 ]] && break
  jq -r '.[] | [.id, .path_with_namespace, (.statistics.repository_size // 0)] | @tsv' <<<"$lot" |
  while IFS=$'\t' read -r id chemin taille; do
    mo=$(( taille / 1024 / 1024 ))
    if (( mo >= SEUIL )); then
      code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "PRIVATE-TOKEN: $TOKEN" \
        "$API/projects/$id/housekeeping?task=$TACHE")
      printf '%-45s %10s  %s (HTTP %s)\n' "$chemin" "$mo" "$TACHE déclenché" "$code"
    else
      printf '%-45s %10s  -\n' "$chemin" "$mo"
    fi
  done
  page=$((page + 1))
done
