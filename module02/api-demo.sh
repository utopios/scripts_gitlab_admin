#!/usr/bin/env bash
# Module 02 - Démo API REST avec curl + jq : authentification, pagination offset et
# keyset, impersonation « Sudo », codes retour. Lecture seule.
#
# Usage : ./api-demo.sh
# Jeton : $GITLAB_TOKEN ou ~/.gitlab-token (jeton root de la VM, scopes api + sudo).
set -Eeuo pipefail

URL=${GITLAB_URL:-http://gitlab.formation.lan}
API=$URL/api/v4
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
H=(-H "PRIVATE-TOKEN: $TOKEN")      # ou : -H "Authorization: Bearer $TOKEN"

echo "### 1. Qui suis-je ? (GET /user) et version"
curl -sf "${H[@]}" "$API/user" | jq -c '{id, username, is_admin}'
curl -sf "${H[@]}" "$API/version" | jq -c '{version, enterprise}'

echo; echo "### 2. Pagination offset : en-têtes X-Total, X-Total-Pages, X-Next-Page"
curl -sf -D - -o /dev/null "${H[@]}" "$API/users?per_page=5&page=1" \
  | grep -iE '^x-(total|total-pages|page|per-page|next-page):' | tr -d '\r'

echo; echo "### 3. Boucle offset : tous les utilisateurs, page par page"
page=1; total=0
while [[ -n $page ]]; do
  resp=$(curl -sf -D /tmp/entetes.$$ "${H[@]}" "$API/users?per_page=5&page=$page")
  total=$((total + $(jq length <<<"$resp")))
  page=$(awk 'tolower($1)=="x-next-page:" {print $2}' /tmp/entetes.$$ | tr -d '\r')
done
rm -f /tmp/entetes.$$
echo "utilisateurs lus : $total"

echo; echo "### 4. Pagination keyset (recommandée pour les grands volumes) : suivre Link rel=next"
url="$API/projects?pagination=keyset&order_by=id&sort=asc&per_page=2"
n=0
while [[ -n $url ]]; do
  resp=$(curl -sf -D /tmp/entetes.$$ "${H[@]}" "$url")
  n=$((n + 1)); echo "page $n : $(jq -c 'map(.id)' <<<"$resp")"
  url=$(grep -i '^link:' /tmp/entetes.$$ | grep -o '<[^>]*>; rel="next"' | sed 's/^<//; s/>; rel="next"$//' || true)
done
rm -f /tmp/entetes.$$

echo; echo "### 5. Impersonation : en-tête Sudo (jeton admin avec scope sudo)"
curl -sf "${H[@]}" -H "Sudo: alice.martin" "$API/user" | jq -c '{username}'
curl -sf "${H[@]}" -H "Sudo: alice.martin" "$API/projects?membership=true&simple=true" | jq -r '.[].path_with_namespace'

echo; echo "### 6. Codes retour courants"
code() { curl -s -o /tmp/corps.$$ -w '%{http_code}' "$@"; echo " $(head -c 120 /tmp/corps.$$)"; rm -f /tmp/corps.$$; }
echo -n "jeton invalide       : "; code -H "PRIVATE-TOKEN: glpat-invalide" "$API/user"
echo -n "ressource inexistante: "; code "${H[@]}" "$API/projects/999999"
echo -n "paramètre manquant   : "; code "${H[@]}" -X POST "$API/groups/2/members" -d user_id=3
echo -n "déjà membre          : "; code "${H[@]}" -X POST "$API/groups/2/members" -d user_id=1 -d access_level=50
