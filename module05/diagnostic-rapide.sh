#!/usr/bin/env bash
# Module 5 — « Premier regard » sur une instance GitLab Omnibus en incident.
# Rassemble en ~15 s les informations à consulter AVANT toute hypothèse :
# services, sonde readiness, ressources, dernières erreurs HTTP, exceptions,
# erreurs Gitaly, files Sidekiq, runners.
# Usage : sudo ./diagnostic-rapide.sh [nb_lignes_de_journal_analysées (défaut 5000)]
set -uo pipefail
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"
N=${1:-5000}
L=/var/log/gitlab
TOKEN=${GITLAB_TOKEN:-$(cat /home/formateur/.gitlab-token 2>/dev/null || cat /root/.formation/root-token 2>/dev/null)}
API=http://gitlab.formation.lan/api/v4
titre() { printf '\n=== %s ===\n' "$*"; }
# jq tolérant : ignore les lignes non JSON ou tronquées (disque plein, rotation…)
jqt() { jq -rcR "fromjson? | $1" 2>/dev/null; }

titre "Services Omnibus (gitlab-ctl status) — anomalies uniquement"
gitlab-ctl status | awk '!/^run:/ || $5+0 < 60 {print}' | grep . || echo "tous les services sont « run » depuis plus de 60 s"

titre "Sonde readiness (?all=1) — contrôles en échec"
curl -s --max-time 10 "http://127.0.0.1/-/readiness?all=1" \
  | jq -r 'to_entries[] | select(.value|type=="array") | select(any(.value[]; .status != "ok"))
           | "\(.key): \(.value[0].message // "failed" | .[0:150])"' 2>/dev/null | grep . || echo "readiness OK"

titre "Ressources"
df -h / /var/opt/gitlab 2>/dev/null | awk 'NR==1 || !seen[$0]++' | uniq
free -h | head -2
echo "charge : $(cut -d' ' -f1-3 /proc/loadavg)"

titre "Requêtes en erreur 5xx (Rails : production_json + api_json, $N dernières lignes)"
for f in $L/gitlab-rails/production_json.log $L/gitlab-rails/api_json.log; do
  tail -n "$N" "$f" | jqt 'select(.status >= 500) | "\(.status) \(.method) \(.path)"'
done | sort | uniq -c | sort -rn | head -8

titre "Exceptions les plus fréquentes (exceptions_json.log)"
tail -n "$N" $L/gitlab-rails/exceptions_json.log \
  | jqt '"\(.["exception.class"]): \(.["exception.message"] // "" | .[0:110])"' \
  | sort | uniq -c | sort -rn | head -5

titre "Erreurs Gitaly (gitaly/current)"
tail -n "$N" $L/gitaly/current \
  | jqt 'select(.level == "error" and (.wrapper | not)) | "\(.["grpc.method"] // "-") \(.["grpc.request.glProjectPath"] // "") \(.error // .msg | .[0:120])"' \
  | sort | uniq -c | sort -rn | head -5

titre "Workhorse : codes HTTP des $N dernières requêtes"
tail -n "$N" $L/gitlab-workhorse/current | jqt 'select(.msg == "access") | .status' | sort | uniq -c | sort -rn | head -6

titre "Sidekiq : files (backlog / latence) et processus"
curl -s --max-time 10 -H "PRIVATE-TOKEN: $TOKEN" "$API/sidekiq/queue_metrics" \
  | jq -r '.queues | to_entries[] | "\(.key)\tbacklog=\(.value.backlog)\tlatence=\(.value.latency)s"' 2>/dev/null || echo "API Sidekiq indisponible"
curl -s --max-time 10 -H "PRIVATE-TOKEN: $TOKEN" "$API/sidekiq/process_metrics" \
  | jq -r '.processes[] | "processus \(.hostname) files=\(.queues|join(",")) occupés=\(.busy)/\(.concurrency)"' 2>/dev/null

titre "Runners (journal gitlab-runner, 15 dernières minutes)"
journalctl -u gitlab-runner --since "-15min" --no-pager 2>/dev/null \
  | grep -E 'ERROR|WARNING' | sed -E 's/.*gitlab-runner\[[0-9]+\]: //' | cut -c1-140 | sort | uniq -c | sort -rn | head -5 \
  | grep . || echo "aucune erreur"

titre "Dernière reconfiguration"
ls -t $L/reconfigure/*.log 2>/dev/null | head -1 | xargs -r stat -c '%y %n'
echo "gitlab.rb modifié le : $(stat -c %y /etc/gitlab/gitlab.rb)"
