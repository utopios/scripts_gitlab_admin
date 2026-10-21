#!/usr/bin/env bash
# Interrogation de Prometheus via l'API HTTP /api/v1/query
# =============================================================================
# Module 06 - Interroger Prometheus en ligne de commande (API HTTP /api/v1/query)
#
#   ./promql.sh 'expression PromQL'          -> une ligne par série : labels = valeur
#   ./promql.sh -f requetes-cles.txt         -> évalue chaque ligne « titre | expression »
#
# PROM : URL de Prometheus (défaut http://localhost:9090, intégré à Omnibus).
# =============================================================================
set -euo pipefail
PROM=${PROM:-http://localhost:9090}

q() {
  curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '
    if .status != "success" then "ERREUR : \(.error)"
    elif (.data.result | length) == 0 then "  (aucune série)"
    else .data.result[] |
      "  \(.metric | to_entries | map("\(.key)=\(.value)") | join(",") | if . == "" then "-" else . end) = \(.value[1] | tonumber | . * 1000 | round / 1000)"
    end'
}

if [[ ${1:-} == -f ]]; then
  while IFS='|' read -r titre expr; do
    [[ -z $titre || $titre == \#* ]] && continue
    printf '\033[1m%s\033[0m   %s\n' "$titre" "$(echo "$expr" | sed 's/^ *//')"
    q "$expr"
  done < "$2"
else
  q "$1"
fi
