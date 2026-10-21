#!/usr/bin/env bash
# Fonctions communes aux scripts d'injection / de réparation d'incidents (module 5 et 8).
# Ce fichier est « sourcé » par les scripts NN-*-inject.sh et NN-*-reparer.sh ;
# il ne s'exécute pas seul.
#
# Les scripts s'exécutent en root sur la VM du stagiaire (ils se relancent avec sudo
# si besoin). L'état des incidents (sauvegardes, marqueurs) est conservé dans
# /var/lib/formation-incidents (lisible par root uniquement), afin que le stagiaire
# ne trouve pas la « réponse » en fouillant le système de fichiers sans sudo.

set -Eeuo pipefail

ETAT=/var/lib/formation-incidents
GITLAB_URL=${GITLAB_URL:-http://gitlab.formation.lan}
API="$GITLAB_URL/api/v4"

# Relance le script appelant en root si nécessaire
besoin_root() {
  if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
  install -d -m 700 "$ETAT"
}

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }

# Jeton API root : variable GITLAB_TOKEN, sinon ~formateur/.gitlab-token,
# sinon /root/.formation/root-token (créé par le provisionnement de la VM)
jeton() {
  if [[ -n ${GITLAB_TOKEN:-} ]]; then echo "$GITLAB_TOKEN"; return; fi
  local f
  for f in /home/formateur/.gitlab-token /root/.formation/root-token; do
    [[ -s $f ]] && { cat "$f"; return; }
  done
  die "jeton API introuvable (définir GITLAB_TOKEN)"
}

api() {
  local method=$1 chemin=$2
  shift 2
  curl -sS --fail-with-body -X "$method" -H "PRIVATE-TOKEN: $(jeton)" "$API$chemin" "$@"
}

urlenc() { jq -rn --arg v "$1" '$v | @uri'; }

# Chemin disque (hashed storage) du dépôt d'un projet : @hashed/ab/cd/<sha256(id)>.git
chemin_depot() {
  local id=$1 h
  h=$(printf '%s' "$id" | sha256sum | cut -c1-64)
  echo "/var/opt/gitlab/git-data/repositories/@hashed/${h:0:2}/${h:2:2}/$h.git"
}

# Attend que GitLab réponde « ok » à la sonde de disponibilité (toutes dépendances)
attendre_gitlab() {
  local max=${1:-300} t=0
  log "Attente de la disponibilité de GitLab (readiness, ${max}s max)…"
  until curl -fs "http://127.0.0.1/-/readiness?all=1" 2>/dev/null | jq -e '.status == "ok"' >/dev/null 2>&1; do
    sleep 5; t=$((t + 5))
    (( t >= max )) && { log "GitLab n'est pas prêt après ${max}s"; return 1; }
  done
  log "GitLab est prêt."
}

reconfigurer() {
  log "gitlab-ctl reconfigure…"
  gitlab-ctl reconfigure >"$ETAT/reconfigure-$(date +%s).log" 2>&1 \
    || die "reconfigure en échec (voir $ETAT/reconfigure-*.log)"
}

# Marqueurs : un incident injecté laisse un fichier $ETAT/NN.injecte
marquer()     { date -Is > "$ETAT/$1.injecte"; }
est_injecte() { [[ -f $ETAT/$1.injecte ]]; }
demarquer()   { rm -f "$ETAT/$1.injecte"; }
