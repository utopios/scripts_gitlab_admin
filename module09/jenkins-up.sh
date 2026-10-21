#!/usr/bin/env bash
# Installe et démarre Jenkins dans Docker, préconfiguré pour GitLab (module 09).
#  1. compte de service GitLab + jetons (gitlab-compte-service.sh) si absents, mots de passe Jenkins
#  2. image m09-jenkins-gitlab:lts = jenkins/jenkins:lts-jdk21 + plugins (gitlab-plugin, git, pipeline, JCasC)
#  3. conteneur limité en mémoire (VM de 8 à 12 Go) : --memory 1g, heap Java 512 Mo
#  4. réseau : le conteneur résout gitlab.formation.lan vers l'hôte (host-gateway)
#  5. attente de disponibilité + test de la connexion Jenkins -> GitLab
# Relançable : reconstruit l'image (cache Docker) et recrée le conteneur ; JENKINS_HOME est conservé
# dans le volume m09-jenkins-home.
source "$(dirname "$0")/lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
IMAGE=m09-jenkins-gitlab:lts

[[ -s $SECRETS/gitlab-api-token && -s $SECRETS/gitlab-clone-token ]] || "$HERE/gitlab-compte-service.sh"
# Mots de passe Jenkins (admin, et compte "gitlab" utilisé par l'intégration Jenkins de GitLab)
for f in jenkins-admin-password jenkins-gitlab-password; do
  [[ -s $SECRETS/$f ]] || { openssl rand -base64 18 | tr -d '/+=\n' > "$SECRETS/$f"; chmod 600 "$SECRETS/$f"; }
done

log "Construction de l'image $IMAGE"
docker build -q -t "$IMAGE" "$HERE/jenkins" 2> >(grep -v -i -E "legacy builder|buildx|docs.docker.com|^ *$" >&2)

log "(Re)création du conteneur $JENKINS_NAME (port $JENKINS_PORT)"
docker rm -f "$JENKINS_NAME" >/dev/null 2>&1 || true
docker run -d --name "$JENKINS_NAME" --restart unless-stopped \
  --memory 1g --memory-swap 1g --cpus 2 \
  -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Xms256m -Xmx512m" \
  -e JENKINS_URL="$JENKINS_URL" \
  --add-host gitlab.formation.lan:host-gateway \
  -p "$JENKINS_PORT:8080" \
  -v m09-jenkins-home:/var/jenkins_home \
  -v "$SECRETS:/run/secrets:ro" \
  "$IMAGE" >/dev/null

log "Attente du démarrage de Jenkins (1 à 2 min)"
ADMIN_PW=$(cat "$SECRETS/jenkins-admin-password")
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" "http://127.0.0.1:$JENKINS_PORT/api/json") || true
  [[ $code == 200 ]] && break
  # échec rapide si le conteneur redémarre en boucle (erreur JCasC typiquement)
  if [[ $(docker inspect -f '{{.RestartCount}}' "$JENKINS_NAME") -gt 0 ]]; then
    docker logs "$JENKINS_NAME" 2>&1 | grep -m5 -E 'SEVERE|Exception:'; exit 1
  fi
  sleep 5
done
[[ $code == 200 ]] || { docker logs --tail 50 "$JENKINS_NAME"; echo "Jenkins ne répond pas" >&2; exit 1; }
echo "Jenkins $(curl -sI -u "admin:$ADMIN_PW" "http://127.0.0.1:$JENKINS_PORT/" | awk -F': ' 'tolower($1)=="x-jenkins"{print $2}' | tr -d '\r') prêt : $JENKINS_URL"

log "Joignabilité Jenkins -> GitLab (depuis le conteneur)"
docker exec "$JENKINS_NAME" curl -s -o /dev/null -w 'GET http://gitlab.formation.lan/-/readiness -> HTTP %{http_code}\n' \
  http://gitlab.formation.lan/-/readiness

log "Test de la connexion GitLab déclarée dans Jenkins (bouton 'Test Connection')"
JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT
CRUMB=$(curl -s -c "$JAR" -u "admin:$ADMIN_PW" "http://127.0.0.1:$JENKINS_PORT/crumbIssuer/api/json" | jq -r '.crumbRequestField+":"+.crumb')
curl -s -b "$JAR" -u "admin:$ADMIN_PW" -H "$CRUMB" -X POST \
  "http://127.0.0.1:$JENKINS_PORT/descriptorByName/com.dabsquared.gitlabjenkins.connection.GitLabConnection/testConnection" \
  --data-urlencode "url=http://gitlab.formation.lan" --data "apiTokenId=gitlab-api-token" \
  --data "clientBuilderId=autodetect" --data "ignoreCertificateErrors=false" \
  --data "connectionTimeout=10" --data "readTimeout=10" | sed -e 's/<[^>]*>//g'; echo
echo "Connexion : admin / \$(cat $SECRETS/jenkins-admin-password)"
