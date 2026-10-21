#!/usr/bin/env bash
# Module 04 - Correction automatique du TP04 « Audit et sécurisation des accès ».
#
# Usage (dans la VM, en tant que formateur) :
#   ~/scripts/module04/correction-tp04.sh            étapes 1 à 7 (nettoyage des objets m04- à la fin)
#   ~/scripts/module04/correction-tp04.sh --garder   idem, sans l'étape 7 (objets m04- conservés)
#
# Enchaîne les scripts de référence du module et garde leurs traces dans ~/tp04/ :
#   inventaire-acces.csv, plan-actions.md          étapes 1 à 3 (inventaire_acces.py, lecture seule)
#   rotation.log                                   étape 4 (rotation-jeton-pipeline.sh)
#   secret.log                                     étape 5 (secret-historique.sh, sur une COPIE)
#   reglages-avant.json, reglages.log, reglages-apres.json   étape 6 (verifier-reglages.sh)
# puis affiche le tableau « Vérifications » de l'énoncé et lance nettoyage-m04.sh (étape 7).
# Durée : 3 à 5 minutes (pipelines, réécriture d'historique, cache des réglages de 60 s).
set -Eeuo pipefail

ICI=$(cd "$(dirname "$0")" && pwd)
OUT=$HOME/tp04
export T=${GITLAB_TOKEN:-$(cat "$HOME/.gitlab-token")}
export API=http://gitlab.formation.lan/api/v4
export LDAP_ADMIN_PASSWORD=${LDAP_ADMIN_PASSWORD:-LdapAdmin2026!}
GARDER=${1:-}

api() { curl -sS -H "PRIVATE-TOKEN: $T" "$@"; }
etape() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
reglages() { api "$API/application/settings" | jq -S '{admin_mode, rsa_key_restriction, dsa_key_restriction,
  require_personal_access_token_expiry, require_admin_two_factor_authentication, signup_enabled,
  minimum_password_length, runner_token_expiration_interval}'; }

mkdir -p "$OUT"
cd "$ICI"

# =============================================================================================
etape "Étapes 1 à 3 — Inventaire des jetons et des clés, politique, plan d'actions (lecture seule)"
/opt/formation/venv/bin/python ./inventaire_acces.py --sortie "$OUT" 2>&1 | tail -4
echo "actions : P1 $(grep -c 'P1' "$OUT/plan-actions.md" || true) ligne(s) mentionnant P1 ; total $(grep -c '^- \[ \]' "$OUT/plan-actions.md" || true)"

# =============================================================================================
etape "Étape 4 — Rotation du jeton d'un pipeline (root/m04-rotation-ci)"
./rotation-jeton-pipeline.sh root > "$OUT/rotation.log" 2>&1 || echo "ATTENTION : rotation-jeton-pipeline.sh a renvoyé une erreur"
grep -E 'pipeline|HTTP|401|200|expire' "$OUT/rotation.log" | tail -8
PID_ROT=$(api "$API/projects/root%2Fm04-rotation-ci" | jq -r .id)

# =============================================================================================
etape "Étape 5 — Secret commité : copie root/m04-infra-scripts, révocation, réécriture, purge"
./secret-historique.sh root filter-repo > "$OUT/secret.log" 2>&1 || echo "ATTENTION : secret-historique.sh a renvoyé une erreur"
grep -iE 'glpat|révoqu|revoqu|filter-repo|404|200|blob' "$OUT/secret.log" | tail -8

# =============================================================================================
etape "Étape 6 — Réglages d'instance : sauvegarde, application, effets, restauration"
reglages > "$OUT/reglages-avant.json"
./verifier-reglages.sh > "$OUT/reglages.log" 2>&1 || echo "ATTENTION : verifier-reglages.sh a renvoyé une erreur"
grep -E 'admin mode|RSA|PAT sans|restaur' "$OUT/reglages.log" | tail -6
reglages > "$OUT/reglages-apres.json"

# =============================================================================================
etape "Vérifications (tableau de l'énoncé)"
ok() { printf '  [%s] %s\n' "$1" "$2"; }
n=$(grep -c '^- \[ \]' "$OUT/plan-actions.md" || true); p1=$(grep -c 'P1' "$OUT/plan-actions.md" || true)
ok "$([[ $n -gt 0 && $p1 -gt 0 ]] && echo OK || echo KO)" "Plan d'actions : $n action(s), dont des P1"
ecarts=$(grep -oE 'ancien.admin|david.leroy|bot-ci' "$OUT/plan-actions.md" | sort -u | tr '\n' ' ')
ok "$([[ $(echo "$ecarts" | wc -w) -eq 3 ]] && echo OK || echo KO)" "Écarts majeurs dans le plan : $ecarts"
inactifs=$(api "$API/projects/$PID_ROT/access_tokens?state=inactive" | jq length)
ok "$([[ $inactifs -ge 1 ]] && echo OK || echo KO)" "Rotation effective : $inactifs jeton(s) révoqué(s) sur le projet $PID_ROT"
st=$(api "$API/projects/$PID_ROT/pipelines?per_page=1" | jq -r '.[0].status')
ok "$([[ $st == success ]] && echo OK || echo KO)" "Pipeline final : $st"
V=$(mktemp -d)
git clone -q "http://oauth2:$T@gitlab.formation.lan/root/m04-infra-scripts.git" "$V/verif" 2>/dev/null
ng=$(git -C "$V/verif" log --all -p | grep -c glpat- || true); rm -rf "$V"
ok "$([[ $ng -eq 0 ]] && echo OK || echo KO)" "Plus de jeton glpat- dans l'historique de la copie : $ng occurrence(s)"
ok "$(diff -q "$OUT/reglages-avant.json" "$OUT/reglages-apres.json" >/dev/null && echo OK || echo KO)" \
   "Réglages restaurés : $(jq -c '{admin_mode, rsa_key_restriction}' "$OUT/reglages-apres.json")"

# =============================================================================================
if [[ $GARDER != --garder ]]; then
  etape "Étape 7 — Nettoyage des objets m04-"
  ./nettoyage-m04.sh 2>&1 | tail -6
fi
echo
echo "Livrables : $OUT/{inventaire-acces.csv,plan-actions.md,rotation.log,secret.log,reglages-*.json,reglages.log}"
