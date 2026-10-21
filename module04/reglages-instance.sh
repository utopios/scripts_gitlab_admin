#!/usr/bin/env bash
# =============================================================================
# Module 04 - Réglages d'instance liés à la sécurité des accès (API application/settings)
#
#   ./reglages-instance.sh afficher    : valeurs actuelles des réglages suivis
#   ./reglages-instance.sh appliquer   : sauvegarde les valeurs actuelles puis applique la politique
#   ./reglages-instance.sh restaurer   : remet les valeurs sauvegardées
#
# La sauvegarde est faite dans ~/m04-settings-avant.json (une seule fois : un second
# « appliquer » n'écrase pas la sauvegarde d'origine).
# Équivalent UI : Admin > Paramètres > Général (Visibilité et contrôles d'accès,
# Restrictions d'inscription, Paramètres de connexion et d'aide) et > CI/CD (runners).
# Jeton : administrateur avec scope api (+ admin_mode si le mode admin est actif).
# =============================================================================
set -Eeuo pipefail

API=${GITLAB_URL:-http://gitlab.formation.lan}/api/v4
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
BACKUP=~/m04-settings-avant.json

# Politique cible (clé = réglage API, valeur = valeur voulue)
declare -A CIBLE=(
  [require_personal_access_token_expiry]=true   # expiration obligatoire des PAT (max 365 j en CE)
  [rsa_key_restriction]=3072                     # RSA < 3072 bits refusée
  [dsa_key_restriction]=-1                       # -1 = type interdit
  [ecdsa_key_restriction]=256
  [admin_mode]=true                              # re-authentification pour les actions d'admin
  [require_admin_two_factor_authentication]=true # 2FA obligatoire pour les administrateurs
  [two_factor_grace_period]=48                   # heures de grâce avant blocage
  [signup_enabled]=false                         # pas d'inscription libre
  [minimum_password_length]=12
  [runner_token_expiration_interval]=7776000     # jetons de runners d'instance : 90 j (secondes)
  [inactive_resource_access_tokens_delete_after_days]=30
  [deactivate_dormant_users]=true                # désactive les comptes inactifs...
  [deactivate_dormant_users_period]=90           # ... depuis 90 jours
)
CLES=$(printf '%s\n' "${!CIBLE[@]}" | sort | jq -R . | jq -sc .)

api() { local m=$1 p=$2; shift 2; curl -sS --fail-with-body -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "$API$p" "$@"; }
afficher() { api GET /application/settings | jq --argjson k "$CLES" 'with_entries(select(.key as $x | $k | index($x)))'; }

case ${1:-afficher} in
  afficher) afficher ;;
  appliquer)
    [[ -s $BACKUP ]] || { afficher > "$BACKUP"; echo "sauvegarde : $BACKUP" >&2; }
    args=()
    for k in "${!CIBLE[@]}"; do args+=(--data "$k=${CIBLE[$k]}"); done
    api PUT /application/settings "${args[@]}" >/dev/null
    afficher ;;
  restaurer)
    [[ -s $BACKUP ]] || { echo "pas de sauvegarde $BACKUP" >&2; exit 1; }
    # null n'est pas accepté en form-data : on envoie du JSON
    api PUT /application/settings -H 'Content-Type: application/json' --data @"$BACKUP" >/dev/null
    afficher
    rm -f "$BACKUP"; echo "réglages restaurés, sauvegarde supprimée" ;;
  *) echo "usage : $0 afficher|appliquer|restaurer" >&2; exit 2 ;;
esac
