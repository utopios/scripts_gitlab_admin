#!/usr/bin/env bash
# Module 7 — Test de restauration COMPLÈTE (à faire au moins une fois par trimestre,
# idéalement sur une instance de recette ; ici sur la VM de formation).
#   1. crée un projet témoin m07-temoin (fichier + ticket) ;
#   2. sauvegarde complète BACKUP=m07-test-restauration + configuration ;
#   3. « incident » : suppression DÉFINITIVE du projet témoin ;
#   4. restauration : arrêt de puma/sidekiq, gitlab-backup restore, reconfigure, restart ;
#   5. vérifications : projet, fichier, ticket, gitlab:check, gitlab:doctor:secrets.
# Durée sur la VM : ~3 à 5 min. Relançable (le projet témoin est recréé à chaque fois).
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"
TOKEN=${GITLAB_TOKEN:-$(cat /home/formateur/.gitlab-token)}
API=http://gitlab.formation.lan/api/v4
NOM=m07-test-restauration
h() { printf '\n===== %s =====\n' "$*"; }
api() { local m=$1 p=$2; shift 2; curl -sS -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "$API$p" "$@"; }
attendre() {
  for _ in $(seq 1 90); do
    curl -fs "http://127.0.0.1/-/readiness?all=1" 2>/dev/null | jq -e '.status=="ok"' >/dev/null 2>&1 && return 0
    sleep 5
  done; echo "GitLab non prêt"; return 1
}
supprimer_projet() {   # suppression immédiate (2 appels depuis GitLab 18)
  local id=$1 chemin
  api DELETE "/projects/$id" >/dev/null; sleep 2
  chemin=$(api GET "/projects/$id" | jq -r '.path_with_namespace // empty')
  [[ -z $chemin ]] || api DELETE "/projects/$id?permanently_remove=true&full_path=$(jq -rn --arg v "$chemin" '$v|@uri')" >/dev/null
}

h "0. Pré-requis : tous les services démarrés"
gitlab-ctl start >/dev/null
attendre

h "1. Projet témoin"
old=$(api GET "/projects/root%2Fm07-temoin" | jq -r '.id // empty')
[[ -n $old ]] && { supprimer_projet "$old"; sleep 5; }
pid=$(api POST /projects --data name=m07-temoin --data initialize_with_readme=true | jq -r .id)
api POST "/projects/$pid/repository/files/temoin.txt" --data branch=main \
  --data-urlencode content="Contenu témoin $(date -Is)" --data commit_message="Fichier témoin" >/dev/null
api POST "/projects/$pid/issues" --data title="Ticket témoin" >/dev/null
echo "projet m07-temoin créé (id $pid)"

h "2. Sauvegarde"
rm -f /var/opt/gitlab/backups/${NOM}_gitlab_backup.tar
gitlab-backup create BACKUP=$NOM STRATEGY=copy CRON=1
gitlab-ctl backup-etc --backup-path /var/backups/gitlab-config >/dev/null
ls -lh /var/opt/gitlab/backups/${NOM}_gitlab_backup.tar

h "3. Incident simulé : suppression définitive du projet"
supprimer_projet "$pid"; sleep 5
api GET "/projects/root%2Fm07-temoin" | jq -c '{message}'

h "4. Restauration"
gitlab-ctl stop puma
gitlab-ctl stop sidekiq
{ gitlab-ctl status || true; } | grep -E 'puma|sidekiq'   # code retour ≠ 0 quand un service est arrêté
# force=yes : pas de question interactive (sinon confirmer la suppression des tables, etc.)
gitlab-backup restore BACKUP=$NOM force=yes >/tmp/$NOM-restore.log 2>&1
tail -3 /tmp/$NOM-restore.log
gitlab-ctl reconfigure >/dev/null 2>&1
gitlab-ctl restart >/dev/null
attendre

h "5. Vérifications"
api GET "/projects/root%2Fm07-temoin" | jq -c '{id, path_with_namespace}'
echo "temoin.txt : $(api GET "/projects/root%2Fm07-temoin/repository/files/temoin.txt/raw?ref=main")"
echo "tickets : $(api GET "/projects/root%2Fm07-temoin/issues" | jq -r '[.[].title] | join(", ")')"
gitlab-rake gitlab:check SANITIZE=true 2>&1 | grep -E 'Gitaly: |Sidekiq: \.\.\. Running|All migrations up|LDAP authentication'
gitlab-rake gitlab:doctor:secrets 2>&1 | grep -E 'Total:|failures: [1-9]' || true
echo "Restauration testée avec succès."
