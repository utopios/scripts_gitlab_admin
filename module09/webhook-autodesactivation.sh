#!/usr/bin/env bash
# Désactivation automatique des webhooks de projet en échec (GitLab 19.4.2).
# En autogéré, elle dépend du feature flag "ops" auto_disabling_web_hooks, DÉSACTIVÉ par défaut
# (default_enabled: false). Ce script :
#   1. crée un webhook vers une cible morte (127.0.0.1:9, connexion refusée)
#   2. active le flag via l'API /features (comme Feature.enable dans la console Rails)
#   3. déclenche des appels en échec et affiche alert_status / disabled_until après chacun
#   4. remet le flag dans son état initial (sauf GARDER_FLAG=1)
# Seuils (code 19.4.2) : 4e échec consécutif -> temporarily_disabled 1 min, puis 2, 4, 8 min... (max 1 j) ;
# au-delà de 39 échecs -> disabled (définitif, réactivation manuelle). Seuls les hooks de PROJET sont concernés.
source "$(dirname "$0")/lib.sh"
FLAG=auto_disabling_web_hooks
pid=$(api GET "/projects/$(urlenc m09-ci/webhooks-demo)" | jq -r .id)
URL="http://127.0.0.1:9/cible-morte"
# Relançable : on recrée le webhook pour repartir d'un compteur d'échecs (recent_failures) à zéro
for old in $(api GET "/projects/$pid/hooks" | jq -r --arg u "$URL" '.[] | select(.url==$u) | .id'); do
  api DELETE "/projects/$pid/hooks/$old" >/dev/null; done
hid=$(api POST "/projects/$pid/hooks" --data-urlencode "url=$URL" --data "name=m09-cible-morte" \
                         --data "push_events=true" | jq -r .id)
echo "webhook $hid -> $URL"

etat_initial=$(api GET /features | jq -r --arg f "$FLAG" '.[] | select(.name==$f) | .state')
echo "flag $FLAG : ${etat_initial:-non défini (valeur par défaut = off)}"
restaurer() {
  [[ ${GARDER_FLAG:-0} == 1 ]] && return
  # Piège constaté : DELETE /features/<flag> juste après l'activation renvoie 204 mais NE FAIT RIEN
  # (Feature.remove ignore un flag absent du cache "persisted_names", rafraîchi toutes les ~minutes).
  # On remet donc explicitement la valeur : false (= défaut) ou l'état initial.
  api POST "/features/$FLAG" --data "value=$([[ $etat_initial == on ]] && echo true || echo false)" >/dev/null
  echo "flag $FLAG restauré (${etat_initial:-défaut})"
}
trap restaurer EXIT

etat() { api GET "/projects/$pid/hooks/$hid" | jq -r '"alert_status=\(.alert_status)  disabled_until=\(.disabled_until)"'; }
echo "flag OFF -> $(etat)"
api POST "/features/$FLAG" --data "value=true" | jq -c '{name, state}'
# Chaque processus Puma/Sidekiq garde l'état des flags en cache mémoire ~1 min : sans cette attente,
# l'alert_status affiché dépend du worker qui répond (constaté pendant les tests).
echo "attente 65 s (cache des feature flags par processus)"; sleep 65

# Bouton "Test" : limité à 5 appels/min par projet et utilisateur (web_hook_test_limit) -> HTTP 429 au-delà
for i in 1 2 3 4; do
  r=$(curl -s -w ' HTTP %{http_code}' -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$API/projects/$pid/hooks/$hid/test/push_events")
  sleep 1
  printf 'test %d : %s\n         -> %s\n' "$i" "$(cut -c1-90 <<<"$r")" "$(etat)"
done
log "Push réel pendant la désactivation : le webhook ne doit PAS être appelé"
avant=$(api GET "/projects/$pid/hooks/$hid/events?per_page=1" | jq -r '.[0].id')
api POST "/projects/$pid/repository/commits" -H 'Content-Type: application/json' \
  --data "{\"branch\":\"main\",\"commit_message\":\"m09 push pendant désactivation\",\"actions\":[{\"action\":\"create\",\"file_path\":\"d-$(date +%s).txt\",\"content\":\"x\"}]}" >/dev/null
sleep 8
apres=$(api GET "/projects/$pid/hooks/$hid/events?per_page=1" | jq -r '.[0].id')
echo "dernier appel journalisé avant le push : $avant, après : $apres  -> $([[ $avant == "$apres" ]] && echo 'aucun appel (hook désactivé)' || echo 'appel effectué')"
log "Historique des appels du webhook en échec"
api GET "/projects/$pid/hooks/$hid/events?per_page=5" | jq -r '.[] | [.id, .created_at, .trigger, .response_status] | @tsv'
log "Réactivation : corriger la cible puis envoyer un appel de test qui RÉUSSIT (remet recent_failures à 0)"
