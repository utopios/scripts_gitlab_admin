#!/usr/bin/env bash
# Arrête et supprime le conteneur Jenkins (libère ~0,5-1 Go de RAM).
#   ./jenkins-down.sh            conteneur supprimé, données conservées (volume m09-jenkins-home)
#   ./jenkins-down.sh --purge    supprime aussi le volume (jobs, configuration)
#   ./jenkins-down.sh --purge-image   supprime en plus l'image m09-jenkins-gitlab:lts
#     (attention : la reconstruire demande Internet pour télécharger les plugins)
# Relancer ensuite avec ./jenkins-up.sh (puis ./jenkins-jobs.sh après un --purge).
source "$(dirname "$0")/lib.sh"
if docker inspect "$JENKINS_NAME" >/dev/null 2>&1; then
  docker rm -f "$JENKINS_NAME" >/dev/null && echo "conteneur $JENKINS_NAME arrêté et supprimé"
else echo "pas de conteneur $JENKINS_NAME"; fi
if [[ ${1:-} == --purge || ${1:-} == --purge-image ]]; then
  docker volume rm m09-jenkins-home >/dev/null 2>&1 && echo "volume m09-jenkins-home supprimé" || true
fi
if [[ ${1:-} == --purge-image ]]; then
  docker image rm m09-jenkins-gitlab:lts >/dev/null 2>&1 && echo "image m09-jenkins-gitlab:lts supprimée" || true
  docker image prune -f >/dev/null   # couches intermédiaires du build
fi
