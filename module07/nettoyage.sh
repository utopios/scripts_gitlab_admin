#!/usr/bin/env bash
# Module 7 — Nettoyage hebdomadaire. Par défaut en mode SIMULATION (aucune suppression) ;
# passer --appliquer pour exécuter réellement.
#   - fichiers d'artefacts orphelins (sur disque mais plus en base) ;
#   - uploads de projets orphelins ;
#   - références LFS invalides par projet (simulation seulement ici) ;
#   - journaux de maintenance > 90 jours ;
#   - archives de sauvegarde « manuelles » (BACKUP=nom) > 30 jours.
# Les artefacts EXPIRÉS sont supprimés automatiquement par GitLab (tâche cron Sidekiq
# ExpireBuildArtifactsWorker) : rien à faire ici.
set -uo pipefail
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"
DRY=true; [[ ${1:-} == --appliquer ]] && DRY=false
JOURNAL=/var/log/gitlab-maintenance/nettoyage.log
install -d -m 750 "$(dirname "$JOURNAL")"
log() { printf '%s [nettoyage] %s\n' "$(date '+%F %T')" "$*" | tee -a "$JOURNAL"; }
log "Début (DRY_RUN=$DRY)"

log "Artefacts orphelins"
gitlab-rake gitlab:cleanup:orphan_job_artifact_files DRY_RUN=$DRY 2>&1 | grep -E 'Processed|orphan' | tee -a "$JOURNAL"
log "Uploads orphelins"
gitlab-rake gitlab:cleanup:project_uploads DRY_RUN=$DRY 2>&1 | grep -vE '^\s*$' | tail -3 | tee -a "$JOURNAL"
log "Références LFS invalides (simulation, projet par projet)"
for p in $(gitlab-psql -d gitlabhq_production -Atc "select distinct project_id from lfs_objects_projects" 2>/dev/null); do
  gitlab-rake gitlab:cleanup:orphan_lfs_file_references PROJECT_ID="$p" DRY_RUN=true 2>&1 | grep -E 'Found invalid' | sed "s/^/  projet $p : /" | tee -a "$JOURNAL"
done
log "Journaux de maintenance > 90 jours"
find /var/log/gitlab-maintenance -name '*.log.*' -mtime +90 -print $( $DRY || echo -delete ) | tee -a "$JOURNAL"
log "Archives manuelles (nom non horodaté) > 30 jours"
find /var/opt/gitlab/backups -maxdepth 1 -name '*_gitlab_backup.tar' ! -name '[0-9]*' -mtime +30 -print $( $DRY || echo -delete ) | tee -a "$JOURNAL"
log "Fin"
