#!/usr/bin/env bash
# Module 7/8 — Rapport de stockage par projet (API, statistics=true), trié par taille totale.
# Colonnes en Mo : dépôt, LFS, artefacts, total. Usage : ./rapport-stockage.sh [nb=15]
set -euo pipefail
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token 2>/dev/null || cat /home/formateur/.gitlab-token)}
API=http://gitlab.formation.lan/api/v4
N=${1:-15}
{
  page=1
  while :; do
    lot=$(curl -sf -H "PRIVATE-TOKEN: $TOKEN" "$API/projects?statistics=true&per_page=100&page=$page")
    [[ $(jq length <<<"$lot") -eq 0 ]] && break
    jq -r '.[] | .statistics as $s | [.path_with_namespace, $s.repository_size, $s.lfs_objects_size,
           $s.job_artifacts_size, $s.storage_size] | @tsv' <<<"$lot"
    page=$((page + 1))
  done
} | sort -t$'\t' -k5,5 -rn | head -n "$N" \
  | awk -F'\t' 'BEGIN {printf "%-40s %8s %8s %10s %8s\n", "PROJET", "DÉPÔT", "LFS", "ARTEFACTS", "TOTAL"}
                {printf "%-40s %8.1f %8.1f %10.2f %8.1f\n", $1, $2/1048576, $3/1048576, $4/1048576, $5/1048576}'
