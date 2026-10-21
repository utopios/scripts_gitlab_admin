#!/usr/bin/env bash
# Module 7 — Sauvegarde quotidienne de GitLab (à planifier par cron), avec :
#   1. contrôle de l'espace disque avant de commencer ;
#   2. gitlab-backup create (STRATEGY=copy, SKIP configurable) ;
#   3. sauvegarde SÉPARÉE de la configuration (gitlab.rb, gitlab-secrets.json…) via
#      « gitlab-ctl backup-etc » : sans gitlab-secrets.json, une sauvegarde est inexploitable
#      (variables CI, 2FA, jetons chiffrés…) ;
#   4. vérification de l'archive (lisible, version, contenu attendu) ;
#   5. rotation (données : backup_keep_time de gitlab.rb ; configuration : RETENTION_CONF jours) ;
#   6. copie optionnelle hors de la machine (DEST_EXTERNE, ex. montage NFS) ;
#   7. journal dans /var/log/gitlab-maintenance/sauvegarde.log et code retour ≠ 0 en cas d'échec.
# Variables : SKIP (défaut « artifacts,registry »), RETENTION_CONF (défaut 14),
#             DEST_EXTERNE (vide = pas de copie), BACKUP_DIR, CONF_DIR.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"

BACKUP_DIR=${BACKUP_DIR:-/var/opt/gitlab/backups}
CONF_DIR=${CONF_DIR:-/var/backups/gitlab-config}
SKIP=${SKIP:-artifacts,registry}
RETENTION_CONF=${RETENTION_CONF:-14}
DEST_EXTERNE=${DEST_EXTERNE:-}
JOURNAL=/var/log/gitlab-maintenance/sauvegarde.log
install -d -m 750 "$(dirname "$JOURNAL")"
install -d -m 700 "$CONF_DIR"

log() { printf '%s [sauvegarde] %s\n' "$(date '+%F %T')" "$*" | tee -a "$JOURNAL"; }
echec() { log "ÉCHEC : $*"; exit 1; }
trap 'echec "erreur ligne $LINENO"' ERR

# 1. Espace disque : il faut au moins la taille de la dernière archive + 20 %
derniere=$(ls -t "$BACKUP_DIR"/*_gitlab_backup.tar 2>/dev/null | head -1 || true)
besoin=$(( ${derniere:+$(stat -c %s "$derniere")} + 0 ))
besoin=$(( besoin * 12 / 10 + 512*1024*1024 ))
dispo=$(df --output=avail -B1 "$BACKUP_DIR" | tail -1)
(( dispo > besoin )) || echec "espace insuffisant dans $BACKUP_DIR ($dispo octets libres, $besoin requis)"
log "Début (SKIP=$SKIP, $((dispo/1024/1024)) Mo libres)"

# 2. Sauvegarde des données (CRON=1 : sortie réduite, adaptée à cron)
debut=$(date +%s)
gitlab-backup create STRATEGY=copy SKIP="$SKIP" CRON=1 >>"$JOURNAL" 2>&1 \
  || echec "gitlab-backup create a échoué"
archive=$(ls -t "$BACKUP_DIR"/*_gitlab_backup.tar | head -1)
log "Archive : $archive ($(du -h "$archive" | cut -f1), $(( $(date +%s) - debut )) s)"

# 3. Configuration et secrets (archive séparée, root uniquement)
gitlab-ctl backup-etc --backup-path "$CONF_DIR" >>"$JOURNAL" 2>&1 || echec "backup-etc a échoué"
conf=$(ls -t "$CONF_DIR"/gitlab_config_*.tar | head -1)
tar -tf "$conf" | grep -q 'gitlab-secrets.json' || echec "gitlab-secrets.json absent de $conf"
log "Configuration : $conf"

# 4. Vérification de l'archive : lisible, version, base et dépôts présents
contenu=$(tar -tf "$archive") || echec "archive illisible"
grep -q '^db/database.sql.gz$' <<<"$contenu"        || echec "dump de base absent"
grep -q '^repositories/' <<<"$contenu"              || echec "dépôts absents"
version=$(tar -xOf "$archive" backup_information.yml | awk '/:gitlab_version:/ {print $2}')
[[ $version == "$(cat /opt/gitlab/embedded/service/gitlab-rails/VERSION)" ]] \
  || echec "version de l'archive ($version) différente de l'instance"
tar -xOf "$archive" db/database.sql.gz | gzip -t || echec "dump PostgreSQL corrompu"
log "Vérification OK (GitLab $version, $(grep -c '\.bundle$' <<<"$contenu") bundle(s) de dépôts)"

# 5. Rotation de la configuration (les archives de données sont purgées par
#    gitlab-backup selon gitlab_rails['backup_keep_time'])
find "$CONF_DIR" -name 'gitlab_config_*.tar' -mtime +"$RETENTION_CONF" -print -delete | sed 's/^/  supprimé : /' >>"$JOURNAL"

# 6. Copie externe (la sauvegarde sur le même disque ne protège pas d'une perte du serveur)
if [[ -n $DEST_EXTERNE ]]; then
  install -d -m 700 "$DEST_EXTERNE"
  cp "$archive" "$conf" "$DEST_EXTERNE"/ || echec "copie vers $DEST_EXTERNE impossible"
  log "Copié vers $DEST_EXTERNE"
fi
log "Fin OK"
