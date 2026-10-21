#!/usr/bin/env bash
# Incident 06 — Runner « shell » rejeté (jeton réinitialisé côté GitLab)
# Simule une rotation du jeton d'authentification du runner faite dans GitLab sans mise à
# jour de /etc/gitlab-runner/config.toml. Les jobs tagués « shell » restent « pending ».
#
# Détail : Workhorse met en cache (Redis, clé runner:build_queue:<jeton>, TTL ~1 h) la file
# de chaque jeton (long polling). Sans intervention, le runner continue de recevoir des 204
# pendant jusqu'à une heure avant le premier 403. On supprime cette clé pour que le
# symptôme apparaisse immédiatement (équivaut à « le lendemain matin »).
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"

N=06
RUNNER=${RUNNER:-runner-shell}
CONF=/etc/gitlab-runner/config.toml
est_injecte $N && die "incident $N déjà injecté"

rid=$(api GET "/runners/all?per_page=100" | jq -r --arg d "$RUNNER" '.[] | select(.description == $d) | .id')
[[ -n $rid ]] || die "runner $RUNNER introuvable"
ancien=$(awk -v n="$RUNNER" '$0 ~ "name = \""n"\"" {f=1} f && /^  token = / {gsub(/"/,"",$3); print $3; exit}' "$CONF")
[[ -n $ancien ]] || die "jeton du runner $RUNNER introuvable dans $CONF"
cp -p "$CONF" "$ETAT/$N-config.toml.avant"
api POST "/runners/$rid/reset_authentication_token" >/dev/null
gitlab-redis-cli del "runner:build_queue:$ancien" >/dev/null
marquer $N
log "Incident $N injecté (runner $RUNNER, id $rid)."
