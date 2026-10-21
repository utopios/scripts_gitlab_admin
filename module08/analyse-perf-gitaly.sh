#!/usr/bin/env bash
# Module 8 — Indicateurs de performance Gitaly via Prometheus (http://127.0.0.1:9090).
# Usage : ./analyse-perf-gitaly.sh [période=1h]
set -uo pipefail
PROM=${PROM:-http://127.0.0.1:9090}
P=${1:-1h}
q() {
  printf '\n### %s\n%s\n' "$1" "$2"
  curl -s -G "$PROM/api/v1/query" --data-urlencode "query=$2" \
    | jq -r '.data.result[] | "\(.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(" "))\t\(.value[1] | tonumber | . * 1000 | round / 1000)"' \
    | sort -t$'\t' -k2,2 -g -r | head -10
}
q "Appels gRPC Gitaly par méthode ($P)" \
  "topk(10, sum by (grpc_method) (increase(grpc_server_handled_total{job=\"gitaly\"}[$P])))"
q "Appels gRPC en erreur, par code ($P)" \
  "sum by (grpc_method, grpc_code) (increase(grpc_server_handled_total{job=\"gitaly\", grpc_code!=\"OK\"}[$P])) > 0"
q "Latence p95 (s) par méthode ($P)" \
  "histogram_quantile(0.95, sum by (le, grpc_method) (rate(grpc_server_handling_seconds_bucket{job=\"gitaly\"}[$P]))) > 0"
q "Volume servi aux clients (clone/fetch, octets, $P)" \
  "sum(increase(gitaly_pack_objects_served_bytes_total[$P]))"
q "Temps CPU des commandes git lancées par Gitaly (s, $P)" \
  "topk(5, sum by (cmd, subcmd) (increase(gitaly_command_cpu_seconds_total[$P])))"
q "Tâches de housekeeping effectuées (24h)" \
  "sum by (housekeeping_task, status) (increase(gitaly_housekeeping_tasks_total[24h])) > 0"
