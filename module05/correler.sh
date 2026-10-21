#!/usr/bin/env bash
# Module 5 — Suivre une requête dans tous les composants grâce à son correlation_id.
# Le correlation_id est renvoyé au client dans l'en-tête X-Request-Id ; il est propagé
# de Workhorse vers Rails (Puma), Gitaly et les tâches Sidekiq déclenchées.
# Usage : sudo ./correler.sh <correlation_id>
set -uo pipefail
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"
CID=${1:?usage: $0 <correlation_id>}
L=/var/log/gitlab

resume() {   # une ligne lisible par événement, selon le composant
  jq -rcR --arg f "$1" 'fromjson? |
    if   $f == "workhorse" then "\(.time) \(.method) \(.uri) -> \(.status // "") \(.duration_ms // "")ms backend=\(.backend_id // "") \(.error // "" | .[0:100])"
    elif $f == "gitaly"    then "\(.time) \(.["grpc.method"] // .msg) \(.["grpc.code"] // "") \(.["grpc.time_ms"] // "")ms \(.["grpc.request.glProjectPath"] // "") \(.error // "" | .[0:100])"
    elif $f == "sidekiq"   then "\(.time) \(.class) \(.job_status // "") \(.duration_s // "")s \(.error_message // "" | .[0:100])"
    elif $f == "exceptions" then "\(.time) \(.["exception.class"]): \(.["exception.message"] // "" | .[0:120])"
    elif $f == "application" or $f == "audit" then "\(.time) \(.severity // "") \(.message // .event_name // "" | .[0:140])"
    else "\(.time) \(.method // "") \(.path // "") -> \(.status // "") \(.duration_s // "")s user=\(.username // .["meta.user"] // "-")"
    end' 2>/dev/null
}

declare -A FICHIERS=(
  [1-workhorse]=$L/gitlab-workhorse/current
  [2-production]=$L/gitlab-rails/production_json.log
  [3-api]=$L/gitlab-rails/api_json.log
  [4-application]=$L/gitlab-rails/application_json.log
  [5-audit]=$L/gitlab-rails/audit_json.log
  [6-exceptions]=$L/gitlab-rails/exceptions_json.log
  [7-gitaly]=$L/gitaly/current
  [8-sidekiq]=$L/sidekiq/current
)
for cle in $(printf '%s\n' "${!FICHIERS[@]}" | sort); do
  f=${FICHIERS[$cle]}; nom=${cle#*-}
  [[ -f $f ]] || continue
  lignes=$(grep -F "$CID" "$f" || true)
  [[ -n $lignes ]] || continue
  printf '\n--- %s (%s) : %s ligne(s)\n' "$nom" "$f" "$(grep -c . <<<"$lignes")"
  resume "$nom" <<<"$lignes" | head -15
done
# nginx (format texte) : le correlation_id n'y figure pas, rien à chercher
