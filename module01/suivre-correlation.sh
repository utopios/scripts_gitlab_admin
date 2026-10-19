#!/usr/bin/env bash
# Module 01 - Suivre une requête dans tous les journaux GitLab grâce au correlation_id.
#
# Usage : sudo ./suivre-correlation.sh <correlation_id> [--suivre-hooks]
#
# Le correlation_id est renvoyé au client dans l'en-tête HTTP « X-Request-Id »
# (et dans X-Gitlab-Meta). Il est écrit par Workhorse, Rails (production_json,
# api_json, application_json…), Sidekiq et Gitaly.
#
# --suivre-hooks : lors d'un git push, les hooks Gitaly rappellent l'API interne
# (/api/v4/internal/allowed, pre_receive, post_receive). Constat en 19.4.2 : côté
# Rails ces appels reçoivent un NOUVEAU correlation_id, repris ensuite par Sidekiq
# (PostReceiveWorker). Cette option retrouve ces appels par l'horodatage et les suit.
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Lancer avec sudo" >&2; exit 1; }
[[ $# -ge 1 ]] || { echo "Usage : $0 <correlation_id> [--suivre-hooks]" >&2; exit 2; }
CID=$1
SUIVRE=${2:-}
LOGS=/var/log/gitlab

# Résumé d'une ligne JSON quel que soit le composant
resume='[ (.time // ."@timestamp" // "?"),
  (.msg // .message // "" | tostring | .[0:40]),
  (.controller // "") + (if .action then "#" + .action else "" end),
  (.route // .uri // .path // .url // ""),
  (."grpc.method" // .class // ""),
  ((.status // ."grpc.code" // .job_status // "") | tostring),
  ((.duration_s // .duration_ms // ."grpc.time_ms" // "") | tostring),
  (.username // .user // ."meta.user" // .gl_user_name // "") ]
  | map(select(. != "")) | join(" | ")'

tracer() {
  local cid=$1
  echo "=== correlation_id $cid"
  grep -rl --include='*' "$cid" "$LOGS" 2>/dev/null | sort | while read -r f; do
    echo "--- ${f#$LOGS/}"
    # Les fichiers runit (current) et *_json.log sont en JSON ; les autres sont affichés bruts
    grep -h "$cid" "$f" | while IFS= read -r ligne; do
      jq -r "$resume" <<<"$ligne" 2>/dev/null || echo "${ligne:0:200}"
    done
  done
}

tracer "$CID"

if [[ $SUIVRE == --suivre-hooks ]]; then
  # Appels à l'API interne émis par Gitaly pour ce correlation_id
  grep -h "$CID" "$LOGS/gitaly/current" 2>/dev/null \
    | jq -r 'select(.msg=="Finished HTTP request" and (.url|test("internal/"))) | "\(.time) \(.url|sub(".*/internal/";""))"' \
    | while read -r t route; do
        sec=${t:0:19}   # même seconde
        grep -h "\"/api/:version/internal/$route\"" "$LOGS/gitlab-rails/api_json.log" \
          | jq -r --arg s "$sec" 'select(.time|startswith($s)) | .correlation_id' | sort -u
      done | sort -u | while read -r cid2; do
        echo; echo "(hook interne rattaché par horodatage)"
        tracer "$cid2"
      done
fi
