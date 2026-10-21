#!/usr/bin/env bash
# Crée/met à jour les jobs Jenkins (API REST Jenkins) et les déclencheurs côté GitLab :
#   job m09-app-jenkins      <- webhook de projet GitLab  (URL /project/<job> + jeton secret X-Gitlab-Token)
#   job m09-app-integration  <- intégration "Jenkins" native de GitLab (Basic auth, utilisateur Jenkins "gitlab")
# Relançable : met à jour les jobs existants, le webhook (même URL) et l'intégration.
source "$(dirname "$0")/lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
J="http://127.0.0.1:$JENKINS_PORT"
ADMIN="admin:$(cat "$SECRETS/jenkins-admin-password")"
JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT
CRUMB=$(curl -sf -c "$JAR" -u "$ADMIN" "$J/crumbIssuer/api/json" | jq -r '.crumbRequestField+":"+.crumb')
jcurl() { curl -sS -f -b "$JAR" -u "$ADMIN" -H "$CRUMB" "$@"; }

# Jeton secret partagé GitLab <-> job (généré une fois)
[[ -s $SECRETS/webhook-app-jenkins ]] || { openssl rand -hex 20 | tr -d '\n' > "$SECRETS/webhook-app-jenkins"; chmod 600 "$SECRETS/webhook-app-jenkins"; }
HOOK_SECRET=$(cat "$SECRETS/webhook-app-jenkins")

put_job() {   # put_job <nom> <projet gitlab> <secret ou vide> <description>
  local name=$1 proj=$2 secret=$3 desc=$4 xml
  xml=$(sed -e "s|@DESCRIPTION@|$desc|" -e "s|@SECRET_TOKEN@|$secret|" \
            -e "s|@REPO_URL@|$GITLAB_URL/$proj.git|" "$HERE/jenkins/job-template.xml")
  if jcurl -o /dev/null "$J/job/$name/api/json" 2>/dev/null; then
    jcurl -X POST -H 'Content-Type: application/xml' --data-binary "$xml" "$J/job/$name/config.xml" && echo "job $name mis à jour"
  else
    jcurl -X POST -H 'Content-Type: application/xml' --data-binary "$xml" "$J/createItem?name=$name" && echo "job $name créé"
  fi
}
put_job m09-app-jenkins     m09-ci/app-jenkins     "$HOOK_SECRET" "Déclenché par webhook GitLab (m09-ci/app-jenkins)"
put_job m09-app-integration m09-ci/app-integration ""             "Déclenché par l'intégration Jenkins de GitLab (m09-ci/app-integration)"

log "Webhook GitLab m09-ci/app-jenkins -> Jenkins"
pid=$(api GET "/projects/$(urlenc m09-ci/app-jenkins)" | jq -r .id)
HOOK_URL="${JENKINS_URL%/}/project/m09-app-jenkins"
hid=$(api GET "/projects/$pid/hooks" | jq -r --arg u "$HOOK_URL" '.[] | select(.url==$u) | .id' | head -1)
args=(--data-urlencode "url=$HOOK_URL" --data-urlencode "name=Jenkins m09-app-jenkins"
      --data "token=$HOOK_SECRET" --data "push_events=true" --data "merge_requests_events=true"
      --data "note_events=true" --data "tag_push_events=false" --data "enable_ssl_verification=true")
if [[ -n $hid ]]; then api PUT "/projects/$pid/hooks/$hid" "${args[@]}" >/dev/null
else hid=$(api POST "/projects/$pid/hooks" "${args[@]}" | jq -r .id); fi
api GET "/projects/$pid/hooks/$hid" | jq -c '{id, url, token_present, push_events, merge_requests_events, note_events, alert_status}'

log "Intégration Jenkins de m09-ci/app-integration"
pid2=$(api GET "/projects/$(urlenc m09-ci/app-integration)" | jq -r .id)
api PUT "/projects/$pid2/integrations/jenkins" --data-urlencode "jenkins_url=${JENKINS_URL%/}" \
  --data "project_name=m09-app-integration" --data "username=gitlab" \
  --data-urlencode "password=$(cat "$SECRETS/jenkins-gitlab-password")" \
  --data "push_events=true" --data "merge_requests_events=true" --data "tag_push_events=false" \
  | jq -c '{slug, active, push_events, merge_requests_events, properties}'
