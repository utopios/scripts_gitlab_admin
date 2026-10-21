#!/usr/bin/env bash
# Réparation de l'incident 05 : rendre le dépôt à git:git, puis vérifier qu'aucun fichier
# de git-data n'appartient à un autre utilisateur.
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"
N=05

d=$(cat "$ETAT/$N-depot" 2>/dev/null || true)
[[ -n $d ]] && chown -R git:git "$d"
# Contrôle global : tout git-data doit appartenir à git
autres=$(find /var/opt/gitlab/git-data/repositories ! -user git | head -5)
[[ -z $autres ]] || { echo "$autres"; die "fichiers n'appartenant pas à git"; }
id=$(api GET "/projects/$(urlenc "${PROJET:-plateforme/backend/api-commandes}")" | jq -r .id)
code=$(curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $(jeton)" "$API/projects/$id/repository/tree")
log "API repository/tree : HTTP $code"
[[ $code == 200 ]] || die "le dépôt n'est toujours pas lisible"
demarquer $N
log "Incident $N réparé."
