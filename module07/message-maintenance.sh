#!/usr/bin/env bash
# Module 7 — Annoncer une fenêtre de maintenance (bannière « broadcast message », CE).
# Usage :
#   ./message-maintenance.sh creer "2026-10-20 20:00" "2026-10-20 22:00" "Texte…"
#   ./message-maintenance.sh lister
#   ./message-maintenance.sh supprimer <id>
# Le message s'affiche à tous les utilisateurs entre starts_at et ends_at (heures locales
# converties en ISO 8601). Le « mode maintenance » (lecture seule) est Premium : en CE,
# on annonce + on arrête les services concernés pendant la fenêtre.
set -euo pipefail
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token 2>/dev/null || cat /home/formateur/.gitlab-token)}
API=http://gitlab.formation.lan/api/v4
case ${1:-lister} in
  creer)
    debut=$(date -d "$2" -Iseconds); fin=$(date -d "$3" -Iseconds)
    curl -sf -X POST -H "PRIVATE-TOKEN: $TOKEN" "$API/broadcast_messages" \
      --data-urlencode "message=$4" --data-urlencode "starts_at=$debut" --data-urlencode "ends_at=$fin" \
      --data broadcast_type=banner --data theme=red --data dismissable=false \
      | jq -c '{id, message, starts_at, ends_at, active}' ;;
  lister)
    curl -sf -H "PRIVATE-TOKEN: $TOKEN" "$API/broadcast_messages" | jq -c '.[] | {id, message, starts_at, ends_at, active}' ;;
  supprimer)
    curl -sf -o /dev/null -w 'HTTP %{http_code}\n' -X DELETE -H "PRIVATE-TOKEN: $TOKEN" "$API/broadcast_messages/$2" ;;
  *) echo "usage : $0 creer|lister|supprimer …"; exit 1 ;;
esac
