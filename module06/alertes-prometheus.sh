#!/usr/bin/env bash
# =============================================================================
# Module 06 - Alertes avec le Prometheus et l'Alertmanager INTÉGRÉS à Omnibus
#
#   ./alertes-prometheus.sh            installe les règles m06, configure un récepteur
#                                      webhook, déclenche M06Rafale404 et suit l'alerte
#   ./alertes-prometheus.sh nettoyer   retire les règles et restaure alertmanager.yml
#
# ATTENTION : alertmanager.yml est GÉNÉRÉ par « gitlab-ctl reconfigure » à partir de
# gitlab.rb. Ici on le modifie directement pour le test (temporaire, écrasé au prochain
# reconfigure). Configuration durable équivalente dans /etc/gitlab/gitlab.rb :
#   alertmanager['receivers'] = [{ 'name' => 'm06-webhook',
#     'webhook_configs' => [{ 'url' => 'http://127.0.0.1:9097/alertmanager', 'send_resolved' => true }] }]
#   alertmanager['routes'] = [{ 'receiver' => 'm06-webhook', 'matchers' => ['alertname=~"M06.*"'],
#     'group_wait' => '10s', 'group_interval' => '1m' }]
# Les fichiers *.rules de /var/opt/gitlab/prometheus/rules/ sont, eux, chargés tels quels
# (prometheus['rules_files'] = ['/var/opt/gitlab/prometheus/rules/*.rules'] par défaut).
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C   # printf %f attend un point décimal (VM en fr_FR)
cd "$(dirname "$0")"
PROM=http://localhost:9090
AM=http://localhost:9093
RULES=/var/opt/gitlab/prometheus/rules/m06-alertes.rules
AMCONF=/var/opt/gitlab/alertmanager/alertmanager.yml
LOG=/tmp/m06-webhook.log
log() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }

if [[ ${1:-} == nettoyer ]]; then
  sudo rm -f "$RULES"; sudo gitlab-ctl hup prometheus >/dev/null
  if sudo test -f "$AMCONF.m06-avant"; then
    sudo mv "$AMCONF.m06-avant" "$AMCONF"; sudo gitlab-ctl hup alertmanager >/dev/null
  fi
  pkill -f recepteur_webhook.py || true
  echo "règles m06 retirées, alertmanager.yml restauré, récepteur arrêté"; exit 0
fi

log "1. Installation des règles et rechargement de Prometheus (SIGHUP)"
sudo install -m 0644 -o gitlab-prometheus m06-alertes.rules "$RULES"
sudo gitlab-ctl hup prometheus
sleep 5
curl -s "$PROM/api/v1/query" --data-urlencode 'query=prometheus_config_last_reload_successful' \
  | jq -r '"rechargement réussi : \(.data.result[0].value[1])"'
curl -s "$PROM/api/v1/rules" | jq -r '.data.groups[] | select(.name=="m06-exploitation") | .rules[] | "  \(.name) : \(.health)"'

log "2. Récepteur webhook (127.0.0.1:9097) et route Alertmanager"
pgrep -f recepteur_webhook.py >/dev/null || { : > "$LOG"; nohup ./recepteur_webhook.py 9097 "$LOG" >/dev/null 2>&1 & sleep 1; }
sudo test -f "$AMCONF.m06-avant" || sudo cp -p "$AMCONF" "$AMCONF.m06-avant"
# contenu identique à ce que générerait reconfigure avec les réglages gitlab.rb ci-dessus
sudo tee "$AMCONF" >/dev/null <<'EOF'
---
global: {}
templates: []
route:
  receiver: default-receiver
  routes:
  - receiver: m06-webhook
    matchers: ['alertname=~"M06.*"']
    group_wait: 10s
    group_interval: 1m
receivers:
- name: default-receiver
- name: m06-webhook
  webhook_configs:
  - url: http://127.0.0.1:9097/alertmanager
    send_resolved: true
inhibit_rules: []
EOF
sudo gitlab-ctl hup alertmanager; sleep 3
curl -s "$AM/api/v2/status" | jq -r '"Alertmanager \(.versionInfo.version), cluster \(.cluster.status)"'

log "3. Rafale de 404 (≈ 6 req/s, ~2 min ; hors /api une URL inconnue renvoie 302 vers /users/sign_in) pour franchir le seuil de M06Rafale404"
( for i in $(seq 1 720); do curl -s -o /dev/null -H 'Host: gitlab.formation.lan' "http://127.0.0.1/api/v4/projects/m06-inexistant-$i"; sleep 0.15; done ) &
GEN=$!
for i in $(seq 1 24); do
  sleep 10
  st=$(curl -s "$PROM/api/v1/alerts" | jq -r '[.data.alerts[]|select(.labels.alertname=="M06Rafale404")][0].state // "inactive"')
  val=$(curl -s "$PROM/api/v1/query" --data-urlencode 'query=sum(rate(gitlab_workhorse_http_requests_total{code="404"}[1m]))' | jq -r '.data.result[0].value[1] // 0')
  printf '  t+%3ss  404/s=%-6.2f  M06Rafale404=%s\n' $((i*10)) "$val" "$st"
  [[ $st == firing ]] && grep -q M06Rafale404 "$LOG" 2>/dev/null && break
done
wait $GEN 2>/dev/null || true

log "4. Alerte vue par Prometheus, l'Alertmanager et le récepteur"
curl -s "$PROM/api/v1/alerts" | jq -c '.data.alerts[] | select(.labels.alertname|startswith("M06")) | {alertname: .labels.alertname, state, activeAt}'
curl -s "$AM/api/v2/alerts" | jq -c '.[] | select(.labels.alertname|startswith("M06")) | {alertname: .labels.alertname, state: .status.state, receivers: [.receivers[].name]}'
cat "$LOG"
