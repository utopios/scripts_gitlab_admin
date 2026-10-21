#!/usr/bin/env bash
# Incident 05 — Droits cassés sur un dépôt
# Simule une copie/restauration manuelle faite en root (rsync, cp -a…) : le dépôt de
# plateforme/backend/api-commandes appartient à root:root, Gitaly (utilisateur git) ne
# peut plus y accéder. Seul CE projet est touché : 500 sur l'onglet Code, clone/push KO.
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"

N=05
PROJET=${PROJET:-plateforme/backend/api-commandes}
est_injecte $N && die "incident $N déjà injecté"
id=$(api GET "/projects/$(urlenc "$PROJET")" | jq -r .id)
d=$(chemin_depot "$id")
[[ -d $d ]] || die "dépôt introuvable : $d"
echo "$d" > "$ETAT/$N-depot"
chown -R root:root "$d"
marquer $N
log "Incident $N injecté."
