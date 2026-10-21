#!/usr/bin/env bash
# Réparation de l'incident 02 : retirer les réglages maxmemory de gitlab.rb, reconfigurer,
# puis vérifier que Redis n'a plus de limite (maxmemory 0 = valeur par défaut Omnibus).
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"
N=02

sed -i -e "/^### Optimisation memoire Redis (ticket OPS-1742)/d" \
       -e "/^redis\['maxmemory'\]/d" -e "/^redis\['maxmemory_policy'\]/d" /etc/gitlab/gitlab.rb
# supprime les lignes vides laissées en fin de fichier
sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' /etc/gitlab/gitlab.rb
reconfigurer
log "maxmemory Redis : $(gitlab-redis-cli config get maxmemory | tail -1)"
attendre_gitlab 300
code=$(curl -s -o /dev/null -w '%{http_code}' "$GITLAB_URL/users/sign_in")
log "Page de connexion : HTTP $code"
[[ $code == 200 ]] || die "la page de connexion ne répond pas 200"
demarquer $N
log "Incident $N réparé."
