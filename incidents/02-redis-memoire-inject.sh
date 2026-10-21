#!/usr/bin/env bash
# Incident 02 — Redis plein (maxmemory trop bas + politique noeviction)
# Simule une « optimisation » mal dimensionnée dans gitlab.rb. Redis refuse alors toute
# écriture (« OOM command not allowed when used memory > 'maxmemory' ») : les lectures API
# marchent, mais la page de connexion, la création de tickets, les push… échouent en 500.
# gitlab-ctl status et la sonde readiness restent au vert : piège classique.
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"

N=02
est_injecte $N && die "incident $N déjà injecté"
cp -p /etc/gitlab/gitlab.rb "$ETAT/$N-gitlab.rb.avant"
cat >> /etc/gitlab/gitlab.rb <<'RB'

### Optimisation memoire Redis (ticket OPS-1742)
redis['maxmemory'] = '4mb'
redis['maxmemory_policy'] = 'noeviction'
RB
reconfigurer
marquer $N
log "Incident $N injecté."
