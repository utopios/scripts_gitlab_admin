#!/usr/bin/env bash
# Réparation de l'incident 06 : générer un nouveau jeton côté GitLab (API admin),
# l'écrire dans config.toml, redémarrer gitlab-runner (le runner s'est mis en
# « unhealthy » pour 1 h après 3 refus), vérifier le contact.
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"
N=06
RUNNER=${RUNNER:-runner-shell}
CONF=/etc/gitlab-runner/config.toml

rid=$(api GET "/runners/all?per_page=100" | jq -r --arg d "$RUNNER" '.[] | select(.description == $d) | .id')
nouveau=$(api POST "/runners/$rid/reset_authentication_token" | jq -r .token)
[[ $nouveau == glrt-* ]] || die "jeton inattendu"
cp -p "$CONF" "$CONF.$(date +%Y%m%d%H%M%S)"
# Remplace la ligne token = … dans le bloc [[runners]] dont name = "$RUNNER"
awk -v n="$RUNNER" -v t="$nouveau" '
  $0 ~ "name = \""n"\"" {f=1}
  f && /^  token = / {print "  token = \"" t "\""; f=0; next}
  {print}' "$CONF" > "$CONF.tmp" && cat "$CONF.tmp" > "$CONF" && rm -f "$CONF.tmp"
systemctl restart gitlab-runner
sleep 20
contact=$(api GET "/runners/$rid" | jq -r .contacted_at)
log "Runner $RUNNER (id $rid) : dernier contact $contact"
if journalctl -u gitlab-runner --since "-15s" --no-pager | grep -q '403 Forbidden'; then
  die "le runner reçoit encore des 403"
fi
demarquer $N
log "Incident $N réparé."
