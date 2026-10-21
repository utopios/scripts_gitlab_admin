#!/usr/bin/env bash
# Module 8 — Équivalent scripté du bouton « Repository cleanup » de GitLab
# (Settings > Repository > Repository cleanup > « Upload file » puis « Start cleanup »).
# Il n'existe PAS d'endpoint API REST pour cette fonction en 19.4.2 : le script se connecte
# au formulaire web (session + jeton CSRF) avec un compte Owner/administrateur et envoie le
# fichier commit-map produit par git filter-repo (ou object-id-map.old-new.txt de BFG).
# GitLab supprime alors les références internes (refs/keep-around, refs/merge-requests,
# refs/pipelines…) qui pointent encore vers les anciens commits, puis lance un GC.
# Usage : GITLAB_USER=root GITLAB_PASSWORD='…' ./nettoyage-depot-gitlab.sh <groupe/projet> <commit-map>
set -euo pipefail
PROJET=${1:?usage: $0 groupe/projet chemin/commit-map}
MAP=${2:?usage: $0 groupe/projet chemin/commit-map}
U=${GITLAB_URL:-http://gitlab.formation.lan}
USER_=${GITLAB_USER:-root}
PASS=${GITLAB_PASSWORD:-$(sed -n 's/^ *root *: *\([^ ]*\).*/\1/p' ~/formation-credentials.txt | head -1)}
[[ -s $MAP ]] || { echo "fichier commit-map vide ou absent : $MAP"; exit 1; }
J=$(mktemp); trap 'rm -f "$J"' EXIT
csrf() { grep -o 'name="csrf-token" content="[^"]*"' | head -1 | sed 's/.*content="//;s/"$//'; }

# 1. Connexion (compte local : formulaire standard /users/sign_in)
t=$(curl -s -c "$J" -b "$J" "$U/users/sign_in" | csrf)
curl -s -o /dev/null -c "$J" -b "$J" "$U/users/sign_in" --data-urlencode "authenticity_token=$t" \
  --data-urlencode "user[login]=$USER_" --data-urlencode "user[password]=$PASS"
# 2. Jeton CSRF de la page des réglages du dépôt, puis envoi du fichier
t=$(curl -s -c "$J" -b "$J" "$U/$PROJET/-/settings/repository" | csrf)
[[ -n $t ]] || { echo "connexion refusée ou projet inaccessible"; exit 1; }
code=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$J" -b "$J" \
  -F "authenticity_token=$t" -F "project[bfg_object_map]=@$MAP" \
  "$U/$PROJET/-/settings/repository/cleanup")
echo "Envoi du commit-map : HTTP $code"
# 3. Message flash affiché par GitLab après redirection
curl -s -b "$J" "$U/$PROJET/-/settings/repository" | grep -o 'Repository cleanup has started[^<]*\|Failed to upload[^<]*' | head -1
