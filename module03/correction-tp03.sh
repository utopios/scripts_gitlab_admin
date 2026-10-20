#!/usr/bin/env bash
# Module 03 - Correction automatique du TP03 « Génération d'un rapport d'audit des accès ».
#
# Usage (dans la VM, en tant que formateur) : ~/scripts/module03/correction-tp03.sh
#   IGNORER='regex' ...   exceptions acceptées (défaut : objets de test m0N-, tp0N-, jenkins)
#
# Livrables dans ~/tp03/ :
#   audit_acces.py                       script de référence (lecture seule)
#   rapport-audit-AAAAMMJJ.md / .csv     rapport réellement généré
#   plan-remediation.md                  plan pour chaque écart CRITIQUE et ÉLEVÉ (non appliqué)
# puis affiche le tableau « Vérifications » de l'énoncé.
#
# Seule écriture sur l'instance : un jeton root « read_api » temporaire pour prouver la lecture
# seule, révoqué aussitôt (il reste visible comme « révoqué » dans la liste des jetons).
set -Eeuo pipefail

ICI=$(cd "$(dirname "$0")" && pwd)
OUT=$HOME/tp03
A=http://gitlab.formation.lan/api/v4
T=$(cat "$HOME/.gitlab-token")
export LDAP_BIND_PASSWORD=${LDAP_BIND_PASSWORD:-GitlabBind2026!}
IGNORER=${IGNORER:-'^(m0[0-9]|tp0[0-9])-|jenkins'}
JOUR=$(date +%Y%m%d)
SORTIE=rapport-audit-$JOUR

api() { curl -sS -H "PRIVATE-TOKEN: $T" "$@"; }
etape() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

mkdir -p "$OUT"
cp "$ICI/audit_acces.py" "$OUT/" && chmod +x "$OUT/audit_acces.py"
cd "$OUT"

# =============================================================================================
etape "Étape 1 — Collecte : contrôle de la pagination"
XTOTAL=$(curl -s -D - -o /dev/null -H "PRIVATE-TOKEN: $T" "$A/users?per_page=1" | awk 'tolower($1)=="x-total:"{print $2}' | tr -d '\r')
LUS=0; page=1
while :; do   # lecture complète, page par page, comme le fait l'audit
  n=$(api "$A/users?per_page=100&page=$page" | jq length)
  LUS=$((LUS + n)); [[ $n -lt 100 ]] && break; page=$((page + 1))
done
echo "utilisateurs lus : $LUS ; en-tête X-Total : $XTOTAL"

# =============================================================================================
etape "Étapes 2 et 3 — Analyse et rapport (exceptions : $IGNORER)"
set +e
./audit_acces.py --sortie "$SORTIE" --ignorer "$IGNORER"
RC=$?
set -e
echo "code retour : $RC (2 = au moins un écart CRITIQUE)"

etape "Preuve de lecture seule (jeton root read_api temporaire)"
RO=$(api -X POST "$A/users/1/personal_access_tokens" --data-urlencode "name=tp03-lecture-seule" \
      -d "scopes[]=read_api" -d "expires_at=$(date -d '+1 day' +%F)")
RO_ID=$(echo "$RO" | jq -r .id); RO_TOK=$(echo "$RO" | jq -r .token)
set +e
GITLAB_TOKEN=$RO_TOK ./audit_acces.py --sortie /tmp/tp03-lecture-seule --ignorer "$IGNORER" >/dev/null
RC_RO=$?
set -e
sleep 2
METHODES=$(sudo jq -r "select(.token_id==$RO_ID) | .method" /var/log/gitlab/gitlab-rails/api_json.log | sort | uniq -c)
api -o /dev/null -w "jeton $RO_ID révoqué : HTTP %{http_code}\n" -X DELETE "$A/personal_access_tokens/$RO_ID"
rm -f /tmp/tp03-lecture-seule.md /tmp/tp03-lecture-seule.csv
echo "requêtes faites avec le jeton read_api :"; echo "$METHODES"

# =============================================================================================
etape "Étape 4 — Plan de remédiation (CRITIQUE et ÉLEVÉ, non appliqué)"
# Action, outil, responsable et délai proposés selon la catégorie de l'écart
python3 - "$SORTIE.csv" > plan-remediation.md <<'PY'
import csv, sys
REGLES = {
    "Écart LDAP": ("bloquer, retirer les appartenances, révoquer jetons et clés", "offboarding.py <compte> (module 02)", "admin GitLab", "immédiat"),
    "Jetons": ("révoquer ou réduire scopes et durée (rotation)", "API DELETE /personal_access_tokens/:id ou …/rotate", "admin GitLab", "24 h"),
    "Clés SSH": ("supprimer la clé ou la remplacer par ed25519", "API DELETE /users/:id/keys/:key_id ; restriction des types de clés", "admin GitLab", "7 j"),
    "Administrateur": ("retirer le droit admin ou imposer la 2FA", "PUT /users/:id admin=false ; require_admin_two_factor_authentication", "RSSI + admin", "7 j"),
    "Droits": ("ramener au rôle minimal avec expiration, ou remplacer par un jeton de projet", "PUT /groups/:id/members/:user_id", "Owner du groupe", "48 h"),
    "Clés de déploiement": ("passer en lecture seule, ou branches protégées + expiration", "UI projet > Settings > Repository > Deploy keys", "Maintainer du projet", "7 j"),
}
DEFAUT = ("à analyser", "—", "admin GitLab", "30 j")
lignes = [l for l in csv.DictReader(open(sys.argv[1], encoding="utf-8"), delimiter=";")
          if l["criticite"] in ("CRITIQUE", "ELEVE")]
print("# Plan de remédiation (à valider, non appliqué : le module 04 part de cet état)\n")
print("| # | Criticité | Écart | Constat | Action | Outil | Responsable | Délai |")
print("|---|---|---|---|---|---|---|---|")
for i, l in enumerate(lignes, 1):
    action, outil, resp, delai = REGLES.get(l["categorie"], DEFAUT)
    if l["criticite"] == "CRITIQUE" and delai not in ("immédiat",):
        delai = "24 h"
    print(f"| {i} | {l['criticite']} | {l['objet']} | {l['constat']} | {action} | {outil} | {resp} | {delai} |")
print("\nPlanification : lancer l'audit chaque mois (et après chaque vague de départs) avec un jeton")
print("administrateur read_api ; archiver les rapports ; code retour 2 -> alerte.")
PY
echo "plan : $OUT/plan-remediation.md ($(grep -c '^| [0-9]' plan-remediation.md) action(s))"

# =============================================================================================
etape "Vérifications (tableau de l'énoncé)"
ok() { printf '  [%s] %s\n' "$1" "$2"; }
autres=$(echo "$METHODES" | awk '$2!="GET"{print $2}')
ok "$([[ -n $METHODES && -z $autres ]] && echo OK || echo KO)" "Lecture seule : $(echo "$METHODES" | awk '{printf "%s %s ", $1, $2}')(jeton $RO_ID révoqué)"
ok "$([[ $LUS == "$XTOTAL" ]] && echo OK || echo KO)" "Pagination : $LUS utilisateurs lus = X-Total $XTOTAL"
ok "$([[ $RC == 2 ]] && echo OK || echo KO)" "Code retour : $RC (attendu 2) ; avec le jeton read_api : $RC_RO"
H=$(head -1 "$SORTIE.csv" | tr -d '\r')   # le module csv de Python écrit des fins de ligne \r\n
ok "$([[ $H == 'criticite;categorie;objet;constat;recommandation' ]] && echo OK || echo KO)" "En-tête CSV : $H"
NC=$(grep -c '^CRITIQUE;' "$SORTIE.csv" || true)
ok "$([[ $NC -ge 3 ]] && echo OK || echo KO)" "Couverture : $NC écart(s) CRITIQUE (au moins 3 ; 6 sur une instance non modifiée)"
CITES=$(grep -oE 'david.leroy|prestataire.ext|ancien.admin|bot-ci' "$SORTIE.md" | sort -u | tr '\n' ' ')
ok "$([[ $(echo "$CITES" | wc -w) -eq 4 ]] && echo OK || echo KO)" "Comptes cités : $CITES"

echo
echo "Livrables : $OUT/$SORTIE.md  $OUT/$SORTIE.csv  $OUT/plan-remediation.md"
