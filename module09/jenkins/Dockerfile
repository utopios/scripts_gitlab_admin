# Image Jenkins de la formation : LTS officielle + plugins GitLab pré-installés.
# Construite par jenkins-up.sh (docker build -t m09-jenkins-gitlab:lts .)
# Multi-architecture : l'image de base existe en amd64 et arm64.
ARG JENKINS_IMAGE=jenkins/jenkins:lts-jdk21
FROM ${JENKINS_IMAGE}

# Pas d'assistant de premier démarrage : tout vient de JCasC (casc.yaml)
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc.yaml

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

COPY casc.yaml /usr/share/jenkins/ref/casc.yaml.override
