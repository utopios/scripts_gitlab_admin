#!/usr/bin/env bash
# =============================================================================
# Module 06 - Nettoyage des objets de test : règle d'alerte et point de contact Grafana,
# tableau « Exploitation GitLab (M06) » et dossier « M06 Exploitation », règles Prometheus
# m06, alertmanager.yml d'origine, récepteur webhook. Le fichier JSON exporté est conservé.
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")"
G=${GRAFANA_URL:-http://localhost:3000}
AUTH="${GRAFANA_USER:-admin}:${GRAFANA_PASSWORD:-Formation2026!}"

./alerte_grafana.py supprimer
curl -s -u "$AUTH" -X DELETE "$G/api/dashboards/uid/m06-exploitation-gitlab" | jq -r '.title // .message'
curl -s -u "$AUTH" -X DELETE "$G/api/folders/m06-exploitation" | jq -r '.message // .title'
./alertes-prometheus.sh nettoyer
rm -f /tmp/m06-webhook.log
echo "nettoyage m06 terminé"
