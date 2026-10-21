#!/usr/bin/env bash
# Réparation de l'incident 01 : on ne corrige PAS le fichier à la main,
# on le fait régénérer par « gitlab-ctl reconfigure » à partir de /etc/gitlab/gitlab.rb.
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"
N=01

reconfigurer                       # régénère config.toml et redémarre Gitaly
gitlab-ctl restart gitaly >/dev/null   # au cas où le fichier aurait déjà été corrigé
attendre_gitlab 300
gitlab-rake gitlab:gitaly:check 2>&1 | grep -E 'default|Gitaly'
demarquer $N
log "Incident $N réparé."
