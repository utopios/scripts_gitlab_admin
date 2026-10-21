#!/usr/bin/env bash
# Réparation de l'incident 03 : supprimer le fichier, vérifier l'espace, contrôler que
# PostgreSQL et Gitaly ont repris (redémarrage seulement si la sonde reste en échec).
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"
N=03

f=$(cat "$ETAT/$N-fichier" 2>/dev/null || echo /var/tmp/export-gitlab/export-complet-20261014.tar)
rm -f "$f"; rmdir "$(dirname "$f")" 2>/dev/null || true
log "Espace disque : $(df -h / | tail -1)"
if ! attendre_gitlab 60; then
  log "Redémarrage de GitLab"
  gitlab-ctl restart >/dev/null
  attendre_gitlab 300
fi
demarquer $N
log "Incident $N réparé."
