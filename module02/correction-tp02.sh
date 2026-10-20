#!/usr/bin/env bash
# Module 02 - Correction automatique du TP02 « Automatisation de la gestion des utilisateurs ».
#
# Usage (dans la VM, en tant que formateur) :
#   ~/scripts/module02/correction-tp02.sh             joue les étapes 1 à 6, livrables dans ~/tp02/
#   ~/scripts/module02/correction-tp02.sh --nettoyer  supprime jules.nouveau (GitLab + annuaire)
#
# Utilise les scripts de référence du module (sync_ldap_groupes.py, offboarding.py, mapping.yml),
# copiés dans ~/tp02/. Les connexions web de Jules (étape 5) sont rejouées comme un navigateur
# (formulaire « Annuaire Formation »).
#
# Effets voulus par le TP (conservés, sauf --nettoyer pour Jules) : david.leroy retiré de
# plateforme/backend (utilisé au TP03), comptes stagiaireNN créés et inscrits dans sandbox (J+3).
set -Eeuo pipefail

ICI=$(cd "$(dirname "$0")" && pwd)
OUT=$HOME/tp02
URL=http://gitlab.formation.lan
A=$URL/api/v4
T=$(cat "$HOME/.gitlab-token")
export LDAP_BIND_PASSWORD=${LDAP_BIND_PASSWORD:-GitlabBind2026!}
LDAP_ADMIN_PW=${LDAP_ADMIN_PASSWORD:-LdapAdmin2026!}
JULES=jules.nouveau
JULES_PW=Formation2026!
JDN=uid=$JULES,ou=people,dc=formation,dc=lan

api() { curl -sS -H "PRIVATE-TOKEN: $T" "$@"; }
etape() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
ldapm() { ldapmodify -x -H ldap://127.0.0.1 -D cn=admin,dc=formation,dc=lan -w "$LDAP_ADMIN_PW" >/dev/null; }
groupe_ldap() {   # groupe_ldap add|delete <groupe>
  printf 'dn: cn=%s,ou=groups,dc=formation,dc=lan\nchangetype: modify\n%s: member\nmember: %s\n' "$2" "$1" "$JDN" | ldapm
}
uid_de() { api "$A/users?username=$1" | jq -r '.[0].id // empty'; }
etat_de() { api "$A/users?username=$1" | jq -r '.[0].state // "absent"'; }
membres() { api "$A/groups/$(jq -rn --arg v "$1" '$v|@uri')/members?per_page=100" | jq -r '.[] | "\(.username)\t\(.access_level)\t\(.expires_at // "-")"'; }
sync() { ( cd "$OUT" && ./sync_ldap_groupes.py -c mapping.yml "$@" 2>&1 ); }
bilan() { grep -E "Terminé" | sed -E 's/^[0-9-]+ [0-9:,]+ INFO +//'; }

# Connexion web LDAP (onglet « Annuaire Formation ») : affiche l'URL de redirection.
# Succès : redirection vers / (ou le tableau de bord) ; échec : retour à /users/sign_in.
login_ldap() {
  local jar csrf
  jar=$(mktemp)
  csrf=$(curl -s -c "$jar" -b "$jar" "$URL/users/sign_in" | grep -oP 'name="csrf-token" content="\K[^"]+' | sed -n 1p)
  curl -s -o /dev/null -w '%{redirect_url}' -c "$jar" -b "$jar" "$URL/users/auth/ldapmain/callback" \
    --data-urlencode "authenticity_token=$csrf" --data-urlencode "username=$1" --data-urlencode "password=$2"
  rm -f "$jar"
}

# ---------------------------------------------------------------------------------------------
if [[ ${1:-} == --nettoyer ]]; then
  etape "Nettoyage de jules.nouveau"
  id=$(uid_de $JULES)
  [[ -n $id ]] && api -o /dev/null -w "compte GitLab supprimé : %{http_code}\n" -X DELETE "$A/users/$id?hard_delete=true"
  for g in gitlab-users dev-backend ops; do groupe_ldap delete $g 2>/dev/null || true; done
  ldapdelete -x -H ldap://127.0.0.1 -D cn=admin,dc=formation,dc=lan -w "$LDAP_ADMIN_PW" "$JDN" 2>/dev/null \
    && echo "entrée LDAP supprimée" || echo "pas d'entrée LDAP"
  exit 0
fi

mkdir -p "$OUT"
cp "$ICI"/{sync_ldap_groupes.py,offboarding.py,mapping.yml} "$OUT/"
chmod +x "$OUT"/*.py
cd "$OUT"

# =============================================================================================
etape "Étape 1 — État des lieux"
{
  echo "# Groupes LDAP et membres"
  ldapsearch -x -LLL -H ldap://127.0.0.1 -b ou=groups,dc=formation,dc=lan cn member
  for g in plateforme/backend plateforme/frontend ops sandbox; do
    echo "# Membres directs de $g (utilisateur, niveau, expiration)"; membres "$g"
  done
  echo "# plateforme/backend : membres directs + hérités"
  api "$A/groups/plateforme%2Fbackend/members/all?per_page=100" | jq -r '.[] | "\(.username)\t\(.access_level)"'
  cat <<'EOF'
# Analyse
- david.leroy : n'est plus dans dev-backend (ni gitlab-users) mais Maintainer direct de
  plateforme/backend avec une identité LDAP -> la synchro doit le RETIRER.
- prestataire.ext, bot-ci, ancien.admin : comptes locaux -> hors périmètre, signalés seulement.
- hugo.lambert : dans dev-frontend mais hors gitlab-users -> ne peut pas se connecter, ignoré.
- alice.martin : Maintainer > Developer demandé -> niveau conservé.
EOF
} > etape1.txt
echo "état des lieux : $OUT/etape1.txt"

# =============================================================================================
etape "Étape 3 — Simulation, exécution réelle, idempotence, --create-missing"
sync --dry-run --rapport dry-run.md --csv dry-run.csv | bilan || true
sync --rapport reel.md | bilan || true
RELANCE=$(sync --rapport relance.md); printf '%s\n' "$RELANCE" | bilan
sync --dry-run --create-missing | bilan || true
sync --create-missing --rapport create-missing.md | bilan || true
echo "sandbox après --create-missing :"; membres sandbox | sed -n 1,3p; echo "…"

# =============================================================================================
etape "Étape 4 — L'annuaire change : arrivée puis changement d'équipe de $JULES"
cat > jules.ldif <<EOF
dn: $JDN
objectClass: inetOrgPerson
uid: $JULES
cn: Jules Nouveau
givenName: Jules
sn: Nouveau
mail: $JULES@formation.lan
userPassword: $JULES_PW
EOF
ldapadd -x -H ldap://127.0.0.1 -D cn=admin,dc=formation,dc=lan -w "$LDAP_ADMIN_PW" -f jules.ldif >/dev/null
groupe_ldap add gitlab-users; groupe_ldap add dev-backend
echo "memberOf de Jules : $(ldapsearch -x -LLL -H ldap://127.0.0.1 -b ou=people,dc=formation,dc=lan uid=$JULES memberOf | grep -c memberOf) groupe(s)"
sync --dry-run --create-missing | grep -E "$JULES|Terminé" | sed -E 's/^[0-9-]+ [0-9:,]+ INFO +//' || true
sync --create-missing --rapport etape4-arrivee.md | bilan || true
ID_SYNC=$(uid_de $JULES)
groupe_ldap delete dev-backend; groupe_ldap add ops
sync --rapport etape4-changement.md | grep -E "$JULES|Terminé" | sed -E 's/^[0-9-]+ [0-9:,]+ INFO +//' || true
J_OPS=$(membres ops | awk -v j=$JULES '$1==j {print $2}')
J_BACK=$(membres plateforme/backend | awk -v j=$JULES '$1==j' | wc -l)
echo "ops : niveau ${J_OPS:-absent} ; plateforme/backend : $J_BACK ligne(s)"

# =============================================================================================
etape "Étape 5 — Comportement natif de GitLab CE"
REDIR=$(login_ldap $JULES "$JULES_PW")
ID_LOGIN=$(uid_de $JULES)
echo "5.1 connexion web : redirection $REDIR ; compte réutilisé : $([[ $ID_SYNC == "$ID_LOGIN" ]] && echo "oui (id $ID_LOGIN)" || echo "NON ($ID_SYNC/$ID_LOGIN)")"
JT=$(api -X POST "$A/users/$ID_LOGIN/personal_access_tokens" --data-urlencode "name=tp02-jules" \
      -d "scopes[]=read_api" -d "scopes[]=read_repository" -d "expires_at=$(date -d '+7 days' +%F)" | jq -r .token)
groupe_ldap delete gitlab-users
echo "5.2 retiré de gitlab-users ; accès immédiat avec son jeton :"
echo "    git ls-remote : $(git ls-remote "http://$JULES:$JT@gitlab.formation.lan/ops/infra-scripts.git" 2>&1 | grep -c refs/heads) branche(s) visible(s)"
echo "    GET /user     : $(curl -s -o /dev/null -w %{http_code} -H "PRIVATE-TOKEN: $JT" "$A/user") ; état $(etat_de $JULES)"
sudo gitlab-psql -q -c "update users set last_credential_check_at = now() - interval '2 hours' where username='$JULES'" >/dev/null
CODE53=$(curl -s -o /dev/null -w %{http_code} -H "PRIVATE-TOKEN: $JT" "$A/user")
ETAT53=$(etat_de $JULES)
echo "5.3 après « une heure » : GET /user -> $CODE53 ; état $ETAT53"
sleep 1
sudo grep -h "$JULES" /var/log/gitlab/gitlab-rails/application_json.log | jq -r '.message' | grep -E 'does not exist anymore' | tail -1 | sed 's/^/    journal : /'
echo "5.4 déblocage par l'API : $(api -X POST "$A/users/$ID_LOGIN/unblock" | jq -r '.message // .')"
groupe_ldap add gitlab-users
REDIR2=$(login_ldap $JULES "$JULES_PW")
echo "    remis dans gitlab-users + reconnexion web (redirection $REDIR2) : état $(etat_de $JULES)"
sudo grep -h "$JULES" /var/log/gitlab/gitlab-rails/application_json.log | jq -r '.message' | grep -E 'available again' | tail -1 | sed 's/^/    journal : /'

# =============================================================================================
etape "Étape 6 — Départ de $JULES (offboarding)"
./offboarding.py $JULES --dry-run 2>&1 | sed -E 's/^[0-9-]+ [0-9:,]+ INFO +/    /' || true
./offboarding.py $JULES --rapport offboarding-jules.md 2>&1 | sed -E 's/^[0-9-]+ [0-9:,]+ INFO +/    /' || true
./offboarding.py $JULES 2>&1 | sed -E 's/^[0-9-]+ [0-9:,]+ INFO +/    relance : /' || true
echo "Synchronisation relancée (Jules encore dans les groupes LDAP) :"
sync | grep -E "$JULES|Terminé" | sed -E 's/^[0-9-]+ [0-9:,]+ INFO +/    /' || true

# =============================================================================================
etape "Vérifications (tableau de l'énoncé)"
ok() { printf '  [%s] %s\n' "$1" "$2"; }
n=$(printf '%s\n' "$RELANCE" | grep -oP 'Terminé : \K[0-9]+')
ok "$([[ $n == 0 ]] && echo OK || echo KO)" "Idempotence : $n action(s) d'écriture à la relance"
ok "$(membres plateforme/backend | grep -q '^david.leroy' && echo KO || echo OK)" "david.leroy absent de plateforme/backend"
loc=$(membres plateforme/backend | awk '$1=="prestataire.ext"||$1=="bot-ci"{printf "%s(%s) ",$1,$2}')
ok "$([[ $loc == *"prestataire.ext(50)"* && $loc == *"bot-ci(40)"* ]] && echo OK || echo KO)" "Comptes locaux intacts : $loc"
J3=$(date -d '+3 days' +%F)
ns=$(membres sandbox | awk -v d="$J3" '$1 ~ /^stagiaire/ && $3==d' | wc -l)
ok "$([[ $ns -eq 12 ]] && echo OK || echo KO)" "Stagiaires dans sandbox avec expiration $J3 : $ns/12"
ok "$([[ $J_OPS == 40 && $J_BACK == 0 ]] && echo OK || echo KO)" "Jules dans ops (${J_OPS:-absent}) et absent de plateforme/backend (fin de l'étape 4)"
ok "$([[ $ETAT53 == ldap_blocked ]] && echo OK || echo KO)" "ldap_blocked à l'étape 5.3 : $ETAT53"
mb=$(api "$A/users/$ID_LOGIN/memberships" | jq length)
ok "$([[ $(etat_de $JULES) == blocked && $mb == 0 ]] && echo OK || echo KO)" "Offboarding : état $(etat_de $JULES), $mb appartenance(s)"

echo
echo "Livrables : $OUT/{mapping.yml,sync_ldap_groupes.py,offboarding.py,dry-run.md,reel.md,etape4-*.md,offboarding-jules.md}"
echo "Nettoyage de Jules : $0 --nettoyer"
