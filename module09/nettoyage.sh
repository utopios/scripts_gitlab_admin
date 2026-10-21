#!/usr/bin/env bash
# Remet la VM dans l'état d'avant le module 09 : supprime tout ce qui est préfixé m09-.
#   Jenkins (conteneur, volume), system hook + récepteur, groupe m09-ci (et ses projets),
#   utilisateur m09-svc-jenkins (et ses jetons), répertoires ~/m09-jenkins et ~/m09-webhooks.
# Les images jenkins/jenkins:lts-jdk21 et m09-jenkins-gitlab:lts (plugins inclus) sont conservées :
# le TP peut être rejoué sans Internet.
source "$(dirname "$0")/lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/system-hook.sh" stop || true
"$HERE/jenkins-down.sh" --purge
# Groupe de premier niveau : l'API refuse permanently_remove ("only available for subgroups") et
# DELETE ne fait que le marquer pour 30 jours (renommé m09-ci-deletion_scheduled-<id>).
# Pour une suppression immédiate : service de suppression appelé depuis la console Rails.
gid=$(api GET "/groups?search=m09-ci&all_available=true" | jq -r '.[] | select(.full_path|startswith("m09-ci")) | .id' | head -1)
if [[ -n $gid ]]; then
  sudo gitlab-rails runner "g = Group.find($gid); Groups::DestroyService.new(g, User.find_by_username('root')).execute; puts %(groupe #{g.full_path} (#{g.id}) supprimé définitivement)"
fi
uid=$(api GET "/users?username=m09-svc-jenkins" | jq -r '.[0].id // empty')
if [[ -n $uid ]]; then
  api DELETE "/users/$uid?hard_delete=true" >/dev/null
  # suppression asynchrone (Sidekiq) : l'utilisateur reste "blocked" quelques secondes, son e-mail reste pris
  for i in $(seq 1 24); do [[ $(api GET "/users?username=m09-svc-jenkins" | jq length) == 0 ]] && break; sleep 5; done
  echo "utilisateur m09-svc-jenkins ($uid) supprimé"
fi
rm -rf "$M09_DIR" "$HOME/m09-webhooks" && echo "répertoires de travail supprimés"
# Flag remis à "off" par webhook-autodesactivation.sh : on le retire pour revenir à la valeur par défaut
if api GET /features | jq -e '.[] | select(.name=="auto_disabling_web_hooks" and .state=="off")' >/dev/null; then
  api DELETE /features/auto_disabling_web_hooks && echo "flag auto_disabling_web_hooks : retour à la valeur par défaut"
fi
