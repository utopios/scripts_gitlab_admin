#!/usr/bin/env bash
# Module 01 - Retrouver le dépôt d'un projet sur disque (hashed storage).
#
# Usage : sudo ./projet-sur-disque.sh <id_projet | groupe/projet>
#   ex. : sudo ./projet-sur-disque.sh 1
#         sudo ./projet-sur-disque.sh plateforme/backend/api-commandes
#
# Principe : depuis GitLab 13, le chemin d'un dépôt ne dépend que de l'ID du projet :
#   @hashed/<h[0:2]>/<h[2:4]>/<h>.git   avec h = sha256(ID)
# Le chemin « lisible » (groupe/projet) n'apparaît plus nulle part sur disque.
# Lecture seule. Jeton lu dans GITLAB_TOKEN ou ~formateur/.gitlab-token (si chemin fourni).
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Lancer avec sudo" >&2; exit 1; }
[[ $# -eq 1 ]] || { echo "Usage : $0 <id | groupe/projet>" >&2; exit 2; }

REPOS=/var/opt/gitlab/git-data/repositories
API=${GITLAB_URL:-http://gitlab.formation.lan}/api/v4
TOKEN=${GITLAB_TOKEN:-$(cat "${SUDO_USER:+/home/$SUDO_USER}/.gitlab-token" 2>/dev/null || true)}

cible=$1
if [[ $cible =~ ^[0-9]+$ ]]; then
  id=$cible
else
  # Chemin -> ID via l'API (le chemin doit être encodé : / -> %2F)
  enc=$(jq -rn --arg v "$cible" '$v|@uri')
  id=$(curl -sf -H "PRIVATE-TOKEN: $TOKEN" "$API/projects/$enc" | jq -r .id) \
    || { echo "Projet $cible introuvable via l'API" >&2; exit 1; }
fi

h=$(printf '%s' "$id" | sha256sum | cut -d' ' -f1)
rel="@hashed/${h:0:2}/${h:2:2}/$h"
echo "ID projet          : $id"
echo "sha256(ID)         : $h"
echo "Chemin calculé     : $REPOS/$rel.git"

# Vérification croisée dans la base (table project_repositories)
echo "Chemin en base     : $(gitlab-psql -At -c "select disk_path from project_repositories where project_id=$id" 2>/dev/null)"
echo "Chemin GitLab      : $(gitlab-psql -At -c "select path from routes where source_type='Project' and source_id=$id" 2>/dev/null) (table routes)"

if [[ -d $REPOS/$rel.git ]]; then
  echo; echo "Contenu du dépôt nu :"
  ls -1 "$REPOS/$rel.git"
  echo; echo "Taille et objets (git count-objects, binaire git embarqué, utilisateur git) :"
  sudo -u git /opt/gitlab/embedded/bin/git -C "$REPOS/$rel.git" count-objects -vH
  echo; echo "Branches :"
  sudo -u git /opt/gitlab/embedded/bin/git -C "$REPOS/$rel.git" for-each-ref --format='  %(refname:short) %(objectname:short) %(committerdate:short)' refs/heads
  [[ -d $REPOS/$rel.wiki.git ]] && echo "Wiki               : $REPOS/$rel.wiki.git"
else
  echo "ATTENTION : dépôt absent sur disque (projet vide, autre stockage ou incident)" >&2
  exit 1
fi
