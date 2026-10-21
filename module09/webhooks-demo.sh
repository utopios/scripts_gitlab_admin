#!/usr/bin/env bash
# Webhooks de projet : création, test, historique des appels ("Recent events") et redélivrance via l'API.
# Prérequis : récepteur démarré (./system-hook.sh le lance sur le port 8095).
source "$(dirname "$0")/lib.sh"
WD=$HOME/m09-webhooks; PORT=${RECEIVER_PORT:-8095}
curl -sf "http://127.0.0.1:$PORT/" >/dev/null || { echo "Récepteur absent : lancer d'abord ./system-hook.sh" >&2; exit 1; }
gid=$(api GET /groups/m09-ci | jq -r .id)
pid=$(api GET "/projects/$(urlenc m09-ci/webhooks-demo)" 2>/dev/null | jq -r .id) \
  || pid=$(api POST /projects --data "name=webhooks-demo" --data "namespace_id=$gid" --data "initialize_with_readme=true" | jq -r .id)
echo "projet m09-ci/webhooks-demo : id=$pid"

log "1. Webhook de projet vers le récepteur (jeton secret + signature HMAC)"
URL="http://127.0.0.1:$PORT/gitlab/projet"
hid=$(api GET "/projects/$pid/hooks" | jq -r --arg u "$URL" '.[] | select(.url==$u) | .id' | head -1)
args=(--data-urlencode "url=$URL" --data "name=m09-recepteur-projet" --data-urlencode "token=$(cat "$WD/secret")"
      --data-urlencode "signing_token=$(cat "$WD/signing")" --data "push_events=true"
      --data "push_events_branch_filter=main" --data "merge_requests_events=true" --data "issues_events=true")
if [[ -n $hid ]]; then api PUT "/projects/$pid/hooks/$hid" "${args[@]}" >/dev/null
else hid=$(api POST "/projects/$pid/hooks" "${args[@]}" | jq -r .id); fi
api GET "/projects/$pid/hooks/$hid" | jq -c '{id, url, push_events_branch_filter, branch_filter_strategy, token_present, signing_token_present, alert_status}'

log "2. Bouton 'Test' : POST /projects/$pid/hooks/$hid/test/push_events"
api POST "/projects/$pid/hooks/$hid/test/push_events"; echo
log "   Événements réels : un ticket (issues_events) et un push sur main"
api POST "/projects/$pid/issues" --data "title=m09 : ticket de test" >/dev/null
api POST "/projects/$pid/repository/commits" -H 'Content-Type: application/json' \
  --data "{\"branch\":\"main\",\"commit_message\":\"m09 push $(date +%T)\",\"actions\":[{\"action\":\"create\",\"file_path\":\"f-$(date +%s).txt\",\"content\":\"x\"}]}" >/dev/null
sleep 6

log "3. Historique des appels (Recent events) : GET /projects/$pid/hooks/$hid/events"
api GET "/projects/$pid/hooks/$hid/events?per_page=5" \
  | jq -r '.[] | [.id, .trigger, .response_status, (.execution_duration*1000|floor|tostring)+" ms", .request_headers["X-Gitlab-Event"], .request_headers["webhook-signature"][0:14]+"…"] | @tsv' | column -t
log_id=$(api GET "/projects/$pid/hooks/$hid/events?per_page=1" | jq -r '.[0].id')

log "4. Redélivrance de l'appel $log_id : POST /projects/$pid/hooks/$hid/events/$log_id/resend"
api POST "/projects/$pid/hooks/$hid/events/$log_id/resend" | jq -c .
sleep 3
log "   Côté récepteur (3 dernières lignes) :"
tail -n 3 "$WD/events.jsonl" | jq -c '{ts, event, id, kind, verdict}'
