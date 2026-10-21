#!/usr/bin/env bash
# Réparation de l'incident 08 (méthode formateur, rapide) :
#  - si l'objet mis de côté par l'injection existe, on le remet en place ;
#  - sinon, on réinjecte TOUS les objets du clone du développeur via un bundle
#    (méthode décrite dans la correction du TP 08).
# Puis git fsck sur le dépôt serveur.
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"
N=08
PROJET=${PROJET:-plateforme/frontend/portail-web}

id=$(api GET "/projects/$(urlenc "$PROJET")" | jq -r .id)
d=$(chemin_depot "$id")
oid=$(cat "$ETAT/$N-oid" 2>/dev/null || true)

if [[ -n $oid && -f $ETAT/$N-$oid ]]; then
  install -d -o git -g git "$d/objects/${oid:0:2}"
  mv "$ETAT/$N-$oid" "$d/objects/${oid:0:2}/${oid:2}"
  chown git:git "$d/objects/${oid:0:2}/${oid:2}"
else
  clone=/home/formateur/poste-dev/${PROJET##*/}
  [[ -d $clone/.git ]] || die "ni objet sauvegardé ni clone de référence"
  sudo -u formateur git -C "$clone" bundle create /tmp/reparation-$N.bundle --all
  chmod 644 /tmp/reparation-$N.bundle
  sudo -u git git -C "$d" bundle unbundle /tmp/reparation-$N.bundle >/dev/null
  rm -f /tmp/reparation-$N.bundle
fi
sudo -u git git -C "$d" fsck --no-progress && log "git fsck : aucune erreur"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $(jeton)" \
  "$API/projects/$id/repository/files/contact.html/raw?ref=main")
log "Lecture de contact.html via l'API : HTTP $code"
[[ $code == 200 ]] || die "contact.html toujours illisible"
demarquer $N
log "Incident $N réparé."
