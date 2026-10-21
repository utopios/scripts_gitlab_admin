#!/usr/bin/env bash
# Réparation de l'incident 07 : retirer les réglages, reconfigurer, puis réinjecter dans
# les files actives les tâches restées dans la file orpheline « traitements »
# (sinon elles n'y seraient JAMAIS traitées).
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"
N=07

sed -i -e "/^### Files Sidekiq dediees (ticket OPS-1817)/d" \
       -e "/^sidekiq\['routing_rules'\] = \[\['\*', 'traitements'\]\]/d" \
       -e "/^sidekiq\['queue_groups'\] = \['mailers'\]/d" /etc/gitlab/gitlab.rb
# supprime les lignes vides laissées en fin de fichier
sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' /etc/gitlab/gitlab.rb
reconfigurer
attendre_gitlab 300
log "Migration des tâches restées hors des règles de routage"
gitlab-rake gitlab:sidekiq:migrate_jobs:queued
gitlab-rake gitlab:sidekiq:migrate_jobs:retry
gitlab-rake gitlab:sidekiq:migrate_jobs:schedule
sleep 15
log "Files Sidekiq (API /sidekiq/queue_metrics) :"
api GET /sidekiq/queue_metrics | jq -r '.queues | to_entries[] | "  \(.key)\tbacklog=\(.value.backlog)\tlatence=\(.value.latency)s"'
demarquer $N
log "Incident $N réparé."
