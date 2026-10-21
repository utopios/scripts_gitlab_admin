#!/usr/bin/env bash
# Module 8 — Réécriture d'historique CÔTÉ SERVEUR : mutation GraphQL projectBlobsRemove
# (Settings > Repository > « Remove blobs » dans l'interface, rôle Owner, disponible en CE).
# GitLab réécrit lui-même l'historique de toutes les références (branches, tags, refs
# internes) pour retirer les blobs donnés, puis lance un nettoyage. Aucun clone local à
# pousser en force, mais les SHA des commits changent comme avec filter-repo.
# Usage : ./supprimer-blobs-gitlab.sh <groupe/projet> <oid> [<oid>…]
#         ./supprimer-blobs-gitlab.sh <groupe/projet> --plus-de <octets>   (calcule les oid
#         à partir d'un clone nu temporaire ; %(rest) est indispensable : sans lui,
#         cat-file prend toute la ligne « oid chemin » pour un nom d'objet)
set -euo pipefail
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
HOTE=gitlab.formation.lan
PROJET=${1:?usage}; shift
if [[ ${1:-} == --plus-de ]]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  git clone -q --bare "http://oauth2:$TOKEN@$HOTE/$PROJET.git" "$tmp/d.git"
  mapfile -t OIDS < <(git -C "$tmp/d.git" rev-list --objects --all \
    | git -C "$tmp/d.git" cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' \
    | awk -v s="$2" '$1 == "blob" && $3 > s {print $2}')
else
  OIDS=("$@")
fi
(( ${#OIDS[@]} > 0 )) || { echo "aucun blob à supprimer"; exit 0; }
printf 'Blobs à supprimer : %s\n' "${OIDS[@]}"
corps=$(jq -nc --arg p "$PROJET" --args '{
  query: "mutation($p: ID!, $o: [String!]!) { projectBlobsRemove(input: {projectPath: $p, blobOids: $o}) { errors } }",
  variables: {p: $p, o: $ARGS.positional}}' "${OIDS[@]}")
curl -s -H "PRIVATE-TOKEN: $TOKEN" -H "Content-Type: application/json" "http://$HOTE/api/graphql" -d "$corps" | jq -c .
