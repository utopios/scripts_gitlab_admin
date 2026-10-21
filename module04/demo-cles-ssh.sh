#!/usr/bin/env bash
# =============================================================================
# Module 04 - Démo « Gestion des clés SSH »
#  - création d'un utilisateur de test m04-dev et de clés de plusieurs types
#  - dépôt des clés par l'API (avec date d'expiration), empreintes SHA256
#  - recherche du titulaire d'une clé à partir de son empreinte (GET /keys?fingerprint=)
#  - ce que fait sshd : ligne authorized_keys -> gitlab-shell key-<id>
#  - recherche en base : gitlab-shell-authorized-keys-check (AuthorizedKeysCommand)
#  - test d'authentification SSH (ssh -T) et création d'un PAT via SSH
#
# Usage : ./demo-cles-ssh.sh        (relançable ; nettoyage : ./nettoyage-m04.sh)
# Exécuter sur le serveur GitLab (sudo nécessaire pour lire authorized_keys).
# =============================================================================
set -Eeuo pipefail

GITLAB_HOST=${GITLAB_HOST:-gitlab.formation.lan}
API="http://$GITLAB_HOST/api/v4"
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
DIR=~/m04-cles; mkdir -p "$DIR"; chmod 700 "$DIR"
api() { local m=$1 p=$2; shift 2; curl -sS --fail-with-body -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "$API$p" "$@"; }
log() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }

log "1. Utilisateur de test m04-dev"
U=$(api GET "/users?username=m04-dev" | jq -r '.[0].id // empty')
[[ -n $U ]] || U=$(api POST /users --data username=m04-dev --data name="M04 Dev" \
  --data email=m04-dev@formation.lan --data skip_confirmation=true \
  --data-urlencode "password=$(openssl rand -base64 18)" | jq -r .id)
echo "m04-dev = utilisateur $U"
# on repart de zéro : suppression des clés existantes de m04-dev
for k in $(api GET "/users/$U/keys" | jq -r '.[].id'); do api DELETE "/users/$U/keys/$k"; done

log "2. Génération de clés (ed25519 recommandé ; RSA >= 3072 si ed25519 impossible)"
declare -A GEN=([ed25519]="-t ed25519" [rsa2048]="-t rsa -b 2048" [rsa4096]="-t rsa -b 4096" [ecdsa]="-t ecdsa -b 256")
for n in ed25519 rsa2048 rsa4096 ecdsa; do
  [[ -f $DIR/$n ]] || ssh-keygen -q ${GEN[$n]} -N '' -C "m04-dev@$n" -f "$DIR/$n"
  ssh-keygen -lf "$DIR/$n.pub"
done

log "3. Dépôt des clés par l'API, expiration à 90 jours"
EXP=$(date -d +90days +%F)
for n in ed25519 rsa2048 rsa4096 ecdsa; do
  r=$(curl -s -X POST -H "PRIVATE-TOKEN: $TOKEN" "$API/users/$U/keys" --data-urlencode "title=m04-$n" \
      --data-urlencode "key=$(cat "$DIR/$n.pub")" --data "expires_at=$EXP")
  echo "m04-$n : $(jq -c 'if .id then {id,expires_at,usage_type} else . end' <<<"$r")"
done

log "4. Qui possède cette clé ? (recherche par empreinte SHA256, admin)"
FP=$(ssh-keygen -lf "$DIR/ed25519.pub" | awk '{print $2}')
api GET "/keys?fingerprint=$(jq -rn --arg v "$FP" '$v|@uri')" | jq -c '{id,title,user: .user.username}'

log "5. Côté serveur : ligne générée dans authorized_keys de l'utilisateur git"
KID=$(api GET "/users/$U/keys" | jq -r '.[]|select(.title=="m04-ed25519").id')
sudo grep "key-$KID\"" /var/opt/gitlab/.ssh/authorized_keys | cut -c1-150

log "6. Recherche en base (mode AuthorizedKeysCommand) : ce que sshd appellerait"
sudo -u git /opt/gitlab/embedded/service/gitlab-shell/bin/gitlab-shell-authorized-keys-check \
  git git "$(awk '{print $2}' "$DIR/ed25519.pub")" | cut -c1-150

log "7. Test d'authentification SSH et commandes gitlab-shell"
ssh -i "$DIR/ed25519" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -T "git@$GITLAB_HOST" 2>&1 || true
# création d'un PAT via SSH (désactivable : gitlab_shell['pat'] / gitlab-shell config)
ssh -i "$DIR/ed25519" -o IdentitiesOnly=yes -T "git@$GITLAB_HOST" personal_access_token m04-via-ssh read_repository 1 2>&1 \
  | sed -E 's/(glpat-.{6}).*/\1…(masqué)/'
