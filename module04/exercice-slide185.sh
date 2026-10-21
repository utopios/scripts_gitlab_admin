#!/usr/bin/env bash
# Jetons actifs à scope sensible (api, sudo, write_repository) valables encore plus de 90 jours
T=$(cat ~/.gitlab-token)
API=http://gitlab.formation.lan/api/v4

curl -s -H "PRIVATE-TOKEN: $T" "$API/personal_access_tokens?state=active&per_page=100" |
  jq -r --arg now "$(date +%s)" '
    .[]
    | select(any(.scopes[]; . == "api" or . == "sudo" or . == "write_repository"))
    | select(.expires_at != null)
    | . + {jours: (((.expires_at + "T00:00:00Z" | fromdate) - ($now | tonumber)) / 86400 | floor)}
    | select(.jours > 90)
    | [.id, .name, .user_id, .jours]
    | @tsv' |
  while IFS=$'\t' read -r id name uid jours; do
    user=$(curl -s -H "PRIVATE-TOKEN: $T" "$API/users/$uid" | jq -r .username)
    printf '%s\t%s\t%s\t%s j\n' "$id" "$name" "$user" "$jours"
  done
