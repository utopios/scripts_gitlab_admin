#!/usr/bin/env bash
# Incident 07 — Tâches de fond bloquées (file Sidekiq jamais consommée)
# Simule une tentative de « files dédiées » : toutes les tâches sont routées vers une file
# « traitements » mais le seul processus Sidekiq n'écoute que « mailers ».
# Symptômes : pipelines bloqués en « created », push qui n'apparaissent pas dans l'activité,
# MR non mises à jour… alors que gitlab-ctl status et readiness sont au vert.
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"

N=07
est_injecte $N && die "incident $N déjà injecté"
cp -p /etc/gitlab/gitlab.rb "$ETAT/$N-gitlab.rb.avant"
cat >> /etc/gitlab/gitlab.rb <<'RB'

### Files Sidekiq dediees (ticket OPS-1817)
sidekiq['routing_rules'] = [['*', 'traitements']]
sidekiq['queue_groups'] = ['mailers']
RB
reconfigurer
attendre_gitlab 300 || true
marquer $N
log "Incident $N injecté."
