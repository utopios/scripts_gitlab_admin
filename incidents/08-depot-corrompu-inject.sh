#!/usr/bin/env bash
# Incident 08 (module 8) — Dépôt corrompu : objet Git manquant côté serveur
# 1. Un « développeur » (clone dans /home/formateur/poste-dev/portail-web) pousse un
#    commit qui ajoute contact.html sur plateforme/frontend/portail-web.
# 2. Un petit push est stocké par Gitaly sous forme d'objets « loose »
#    (objects/xx/yyyy…) : on supprime le blob de contact.html, comme le ferait un
#    incident disque ou un nettoyage manuel malheureux.
# Symptômes : 500 à l'affichage de contact.html, clone impossible
# (« remote: fatal: unable to read <oid> »), git fsck : « missing blob ».
# Le clone du développeur, lui, est intact : il servira à la réparation.
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"

N=08
PROJET=${PROJET:-plateforme/frontend/portail-web}
POSTE=/home/formateur/poste-dev
est_injecte $N && die "incident $N déjà injecté"

id=$(api GET "/projects/$(urlenc "$PROJET")" | jq -r .id)
d=$(chemin_depot "$id")
url_auth="http://oauth2:$(jeton)@${GITLAB_URL#http://}/$PROJET.git"

install -d -o formateur -g formateur "$POSTE"
rm -rf "$POSTE/${PROJET##*/}"
sudo -u formateur git clone -q "$url_auth" "$POSTE/${PROJET##*/}"
cd "$POSTE/${PROJET##*/}"
sudo -u formateur git remote set-url origin "$GITLAB_URL/$PROJET.git"   # pas de jeton dans .git/config
printf '<!doctype html>\n<html lang="fr"><body>\n<h1>Contact</h1>\n<p>support@formation.lan — mis à jour le %s</p>\n</body></html>\n' \
  "$(date '+%d/%m/%Y %H:%M:%S')" | sudo -u formateur tee contact.html >/dev/null
sudo -u formateur git add contact.html
sudo -u formateur git -c user.name="Emma Bernard" -c user.email=emma.bernard@formation.lan \
  commit -q -m "Ajout de la page contact"
sudo -u formateur git push -q "$url_auth" HEAD:main
oid=$(sudo -u formateur git rev-parse HEAD:contact.html)

obj="$d/objects/${oid:0:2}/${oid:2}"
[[ -f $obj ]] || die "le blob $oid n'est pas stocké en objet loose (dépôt repacké ?) : relancer le script"
mv "$obj" "$ETAT/$N-$oid"
echo "$oid" > "$ETAT/$N-oid"; echo "$d" > "$ETAT/$N-depot"
marquer $N
log "Incident $N injecté (projet $PROJET, blob $oid supprimé)."
