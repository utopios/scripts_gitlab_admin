#!/usr/bin/env bash
# Module 01 - Même action (bloquer un utilisateur) faite par l'API puis par rails runner,
# et ce que chaque méthode laisse dans les journaux. La 3e méthode (interface web)
# se fait à la main : Admin > Utilisateurs > <utilisateur> > Bloquer.
#
# Usage : sudo ./action-trois-facons.sh [utilisateur]     (défaut : tp01-cobaye)
#   L'utilisateur de test est créé s'il n'existe pas. Il est débloqué à la fin.
#   Ne JAMAIS utiliser ce script sur un vrai compte.
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Lancer avec sudo" >&2; exit 1; }
U=${1:-tp01-cobaye}
API=${GITLAB_URL:-http://gitlab.formation.lan}/api/v4
TOKEN=${GITLAB_TOKEN:-$(cat "/home/${SUDO_USER:-formateur}/.gitlab-token")}
RAILS=/var/log/gitlab/gitlab-rails
api() { curl -sS -H "PRIVATE-TOKEN: $TOKEN" "$@"; }

id=$(api "$API/users?username=$U" | jq -r '.[0].id // empty')
if [[ -z $id ]]; then
  id=$(api -X POST "$API/users" --data-urlencode "username=$U" --data-urlencode "name=Cobaye $U" \
        --data-urlencode "email=$U@formation.lan" -d skip_confirmation=true -d force_random_password=true | jq -r .id)
  echo "Utilisateur de test $U créé (id $id)"
fi

echo; echo "### 1. Blocage par l'API REST"
cid=$(api -o /dev/null -D - -X POST "$API/users/$id/block" | awk 'tolower($1)=="x-request-id:" {print $2}' | tr -d '\r')
echo "X-Request-Id renvoyé : $cid"
sleep 2
echo "Fichiers contenant ce correlation_id :"; grep -rl "$cid" /var/log/gitlab | sed 's/^/  /'
echo "api_json.log :"
grep -h "$cid" $RAILS/api_json.log | jq -c '{time, method, path, status, username, token_type, token_id, remote_ip}'
api -o /dev/null -X POST "$API/users/$id/unblock"

echo; echo "### 2. Blocage par gitlab-rails runner (≈ 15-30 s de démarrage)"
debut=$(date -u +%FT%T)
gitlab-rails runner "u = User.find_by!(username: '$U'); u.block!; puts \"état : #{u.reload.state}\""
sleep 2
echo "Requête HTTP associée : aucune (pas de Workhorse, pas de production_json/api_json)."
echo "Seule trace : le job Sidekiq déclenché par le blocage, sans utilisateur ni IP d'origine :"
grep -h "DropPipelinesForBlockedUserWorker" /var/log/gitlab/sidekiq/current \
  | jq -c --arg d "$debut" 'select(.time >= $d and .job_status == "done") | {time, class, args, correlation_id, "meta.caller_id", "meta.user"}'
api -o /dev/null -X POST "$API/users/$id/unblock"

echo; echo "### 3. Blocage par l'interface web (à faire à la main), puis :"
echo "  sudo grep -h '/admin/users/$U/block' $RAILS/production_json.log | jq -c '{time,method,path,controller,action,status,username,remote_ip,correlation_id}'"
echo; echo "État final de $U : $(api "$API/users/$id" | jq -r .state)"
