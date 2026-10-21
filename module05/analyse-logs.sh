#!/usr/bin/env bash
# Module 5 — Recettes jq sur les journaux JSON de GitLab.
# Usage : sudo ./analyse-logs.sh [recette] [nb_lignes]
#   recettes : erreurs | lentes | utilisateurs | refus | depots | sidekiq | tout (défaut)
set -uo pipefail
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"
R=${1:-tout}; N=${2:-20000}
L=/var/log/gitlab
PROD=$L/gitlab-rails/production_json.log API=$L/gitlab-rails/api_json.log
jqt() { jq -rcR "fromjson? | $1" 2>/dev/null; }
t() { printf '\n### %s\n' "$*"; }

erreurs() {
  t "Codes HTTP (Rails web + API)"
  cat <(tail -n "$N" "$PROD") <(tail -n "$N" "$API") | jqt '.status' | sort | uniq -c | sort -rn
  t "5xx : chemin, nombre"
  cat <(tail -n "$N" "$PROD") <(tail -n "$N" "$API") | jqt 'select(.status>=500) | "\(.method) \(.route // .path)"' | sort | uniq -c | sort -rn | head
}
lentes() {
  t "10 requêtes les plus lentes (duration_s, part base de données, part Gitaly)"
  cat <(tail -n "$N" "$PROD") <(tail -n "$N" "$API") \
    | jqt 'select(.duration_s) | [.duration_s, (.db_duration_s // 0), (.gitaly_duration_s // 0), .method, (.route // .path), .correlation_id] | @tsv' \
    | sort -t$'\t' -k1,1 -rn | head -10
}
utilisateurs() {
  t "Appels API par utilisateur et type de jeton"
  tail -n "$N" "$API" | jqt '"\(.username // "anonyme") \(.token_type // "session")"' | sort | uniq -c | sort -rn | head
}
refus() {
  t "401/403 par IP et chemin (tentatives, jetons expirés/révoqués…)"
  cat <(tail -n "$N" "$PROD") <(tail -n "$N" "$API") | jqt 'select(.status==401 or .status==403) | "\(.status) \(.remote_ip) \(.path)"' | sort | uniq -c | sort -rn | head
}
depots() {
  t "Opérations Git HTTP vues par Workhorse (route, statut)"
  tail -n "$N" $L/gitlab-workhorse/current | jqt 'select(.msg=="access" and (.route_id // "" | test("git"))) | "\(.route_id) \(.status)"' | sort | uniq -c | sort -rn
  t "Appels Gitaly en erreur (code gRPC)"
  tail -n "$N" $L/gitaly/current | jqt 'select(.["grpc.code"] and .["grpc.code"] != "OK") | "\(.["grpc.code"]) \(.["grpc.method"])"' | sort | uniq -c | sort -rn | head
}
sidekiq() {
  t "Sidekiq : tâches terminées par classe (top 10) et échecs"
  tail -n "$N" $L/sidekiq/current | jqt 'select(.job_status=="done") | .class' | sort | uniq -c | sort -rn | head
  tail -n "$N" $L/sidekiq/current | jqt 'select(.job_status=="fail") | "\(.class): \(.error_message // "" | .[0:100])"' | sort | uniq -c | sort -rn | head
}
case $R in
  tout) erreurs; lentes; utilisateurs; refus; depots; sidekiq ;;
  erreurs|lentes|utilisateurs|refus|depots|sidekiq) $R ;;
  *) echo "recette inconnue : $R"; exit 1 ;;
esac
