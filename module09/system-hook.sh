#!/usr/bin/env bash
# System hook (GitLab CE, niveau instance) -> récepteur Python webhook-receiver.py
#  1. génère le jeton secret (X-Gitlab-Token) et le jeton de signature (whsec_...) dans ~/m09-webhooks
#  2. démarre le récepteur en arrière-plan sur le port 8095 (s'il ne tourne pas)
#  3. crée (ou met à jour) le system hook "m09-recepteur"
#  4. le teste (POST /hooks/:id) puis provoque de vrais événements (création de projet, membre, push)
#  5. affiche le journal du récepteur
# Arrêt : ./system-hook.sh stop   (supprime le hook et arrête le récepteur)
source "$(dirname "$0")/lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
WD=$HOME/m09-webhooks; mkdir -p "$WD"; chmod 700 "$WD"
PORT=${RECEIVER_PORT:-8095}
HOOK_URL="http://127.0.0.1:$PORT/gitlab/system"
PY=/opt/formation/venv/bin/python

hook_id() { api GET /hooks | jq -r --arg u "$HOOK_URL" '.[] | select(.url==$u) | .id' | head -1; }

if [[ ${1:-} == stop ]]; then
  id=$(hook_id); [[ -n $id ]] && api DELETE "/hooks/$id" && echo "system hook $id supprimé"
  [[ -f $WD/receiver.pid ]] && kill "$(cat "$WD/receiver.pid")" 2>/dev/null && rm -f "$WD/receiver.pid" && echo "récepteur arrêté"
  exit 0
fi

[[ -s $WD/secret ]] || { openssl rand -hex 24 | tr -d '\n' > "$WD/secret"; chmod 600 "$WD/secret"; }
# jeton de signature au format attendu par GitLab : whsec_ + 32 octets aléatoires en base64 (44 caractères)
[[ -s $WD/signing ]] || { printf 'whsec_%s' "$(openssl rand -base64 32)" > "$WD/signing"; chmod 600 "$WD/signing"; }

if ! curl -sf "http://127.0.0.1:$PORT/" >/dev/null; then
  log "Démarrage du récepteur sur le port $PORT"
  WEBHOOK_SECRET=$(cat "$WD/secret") WEBHOOK_SIGNING_TOKEN=$(cat "$WD/signing") \
    nohup "$PY" "$HERE/webhook-receiver.py" --port "$PORT" --log "$WD/events.jsonl" >"$WD/receiver.out" 2>&1 &
  echo $! > "$WD/receiver.pid"; sleep 1; head -2 "$WD/receiver.out"
fi

log "System hook $HOOK_URL"
args=(--data-urlencode "url=$HOOK_URL" --data "name=m09-recepteur" --data "description=Module 09 : récepteur Python"
      --data-urlencode "token=$(cat "$WD/secret")" --data-urlencode "signing_token=$(cat "$WD/signing")"
      --data "push_events=true" --data "merge_requests_events=true" --data "repository_update_events=true"
      --data "tag_push_events=false" --data "enable_ssl_verification=true")
id=$(hook_id)
if [[ -n $id ]]; then api PUT "/hooks/$id" "${args[@]}" >/dev/null; else id=$(api POST /hooks "${args[@]}" | jq -r .id); fi
api GET "/hooks/$id" | jq -c '{id, name, url, push_events, merge_requests_events, repository_update_events, token_present, signing_token_present}'

log "Test du system hook (POST /hooks/$id)"
api POST "/hooks/$id" | jq -c '{event_name, name, path_with_namespace}'

log "Événements réels : création d'un projet, ajout d'un membre, push, suppression"
gid=$(api GET /groups/m09-ci | jq -r .id)
pid=$(api POST /projects --data "name=m09-systemhook-$(date +%H%M%S)" --data "namespace_id=$gid" \
      --data "initialize_with_readme=true" | jq -r .id)
uid=$(api GET "/users?username=alice.martin" | jq -r '.[0].id')
api POST "/projects/$pid/members" --data "user_id=$uid" --data "access_level=20" >/dev/null   # user_add_to_team
api POST "/projects/$pid/repository/commits" -H 'Content-Type: application/json' \
  --data '{"branch":"main","commit_message":"push de test","actions":[{"action":"create","file_path":"a.txt","content":"a"}]}' >/dev/null
delete_project_now "$pid"   # project_destroy (suppression différée puis définitive)
sleep 8   # les system hooks sont envoyés par Sidekiq (asynchrone)

log "Contrôles négatifs : mauvais jeton, puis bon jeton mais sans signature HMAC"
curl -s -w ' (HTTP %{http_code})\n' -X POST -H 'X-Gitlab-Token: mauvais' -H 'X-Gitlab-Event: System Hook' \
  -d '{}' "http://127.0.0.1:$PORT/gitlab/system"
curl -s -w ' (HTTP %{http_code})\n' -X POST -H "X-Gitlab-Token: $(cat "$WD/secret")" -H 'X-Gitlab-Event: System Hook' \
  -d '{}' "http://127.0.0.1:$PORT/gitlab/system"

log "Journal du récepteur ($WD/events.jsonl, 11 dernières lignes)"
tail -n 11 "$WD/events.jsonl" | jq -c '{event, kind, project, user, verdict}'
