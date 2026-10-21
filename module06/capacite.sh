#!/usr/bin/env bash
# =============================================================================
# Module 06 - Capacity planning : état des lieux du stockage et projections
#  1. volumétrie fonctionnelle (API /application/statistics)
#  2. stockage par projet (API /projects?statistics=true) : dépôts, LFS, artefacts, paquets
#  3. occupation disque réelle par répertoire Omnibus (du)
#  4. base PostgreSQL : taille et plus grosses tables
#  5. tendances Prometheus : croissance/jour et projection du disque à 30 jours
#
# Usage : ./capacite.sh  (sur le serveur GitLab ; sudo pour du et gitlab-psql)
# Lecture seule.
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C
API=${GITLAB_URL:-http://gitlab.formation.lan}/api/v4
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
PROM=${PROM:-http://localhost:9090}
api() { curl -sS --fail-with-body -H "PRIVATE-TOKEN: $TOKEN" "$API$1"; }
prom() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "n/a"'; }
log() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
mo() { awk '{printf "%.1f Mo", $1/1048576}'; }

log "1. Volumétrie (API /application/statistics)"
api /application/statistics | jq -r 'to_entries[] | "  \(.key) = \(.value)"' | column -t

log "2. Stockage par projet (API /projects?statistics=true) - total et top 5"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
page=1
while :; do
  r=$(curl -s -D - -o "$TMP.p" -H "PRIVATE-TOKEN: $TOKEN" "$API/projects?statistics=true&per_page=100&page=$page" | awk -F': ' 'tolower($1)=="x-next-page"{print $2}' | tr -d '\r')
  cat "$TMP.p" >> "$TMP"; rm -f "$TMP.p"
  [[ -n $r ]] && page=$r || break
done
jq -s 'add' "$TMP" | jq -r '
  def mo: (. / 1048576 * 10 | round / 10 | tostring) + " Mo";
  "  TOTAL dépôts=\(map(.statistics.repository_size)|add|mo)  LFS=\(map(.statistics.lfs_objects_size)|add|mo)  artefacts=\(map(.statistics.job_artifacts_size)|add|mo)  paquets=\(map(.statistics.packages_size)|add|mo)  wiki=\(map(.statistics.wiki_size)|add|mo)",
  (sort_by(-.statistics.storage_size)[:5][] |
   "  \(.path_with_namespace): total=\(.statistics.storage_size|mo) dépôt=\(.statistics.repository_size|mo) lfs=\(.statistics.lfs_objects_size|mo) artefacts=\(.statistics.job_artifacts_size|mo)")'

log "3. Occupation disque réelle (répertoires Omnibus)"
sudo du -sh /var/opt/gitlab/git-data/repositories /var/opt/gitlab/gitlab-rails/shared/artifacts \
  /var/opt/gitlab/gitlab-rails/shared/lfs-objects /var/opt/gitlab/gitlab-rails/uploads \
  /var/opt/gitlab/gitlab-rails/shared/packages /var/opt/gitlab/postgresql /var/opt/gitlab/backups \
  /var/opt/gitlab/prometheus /var/log/gitlab 2>/dev/null | sed 's/^/  /'
df -h / | sed 's/^/  /'

log "4. PostgreSQL : taille de la base et 5 plus grosses tables"
sudo gitlab-psql -d gitlabhq_production -At -F ' | ' -c "
  SELECT 'base gitlabhq_production', pg_size_pretty(pg_database_size('gitlabhq_production'))
  UNION ALL (SELECT relname, pg_size_pretty(pg_total_relation_size(relid))
             FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 5);" | sed 's/^/  /'

log "5. Tendances Prometheus (fenêtre 6 h : allonger à 7-30 jours en production)"
echo "  disque / libre aujourd'hui      : $(prom 'node_filesystem_avail_bytes{mountpoint="/"}' | mo)"
echo "  disque / libre projeté à J+30   : $(prom 'predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 30*86400)' | mo)"
echo "  croissance base PostgreSQL /jour : $(prom 'deriv(pg_database_size_bytes{datname="gitlabhq_production"}[6h]) * 86400' | mo)"
echo "  saturation disque (SLI Omnibus)  : $(prom 'gitlab_sli:gitlab_component_saturation:ratio{component="disk_space"}')"
echo "  projection saturation disque 30 j: $(prom 'gitlab_sli:gitlab_component_saturation:ratio:predict_linear_30d{component="disk_space"}')"
echo "  mémoire : saturation actuelle    : $(prom 'gitlab_sli:gitlab_component_saturation:ratio{component="memory"}')"
