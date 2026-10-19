#!/usr/bin/env bash
# Module 01 - Cartographie rapide d'une instance GitLab Omnibus.
#
# Usage : sudo ./cartographie.sh            (affichage écran)
#         sudo ./cartographie.sh > carto.md (fiche d'instance en Markdown)
#
# Lecture seule : aucune modification de l'instance. Doit être lancé avec sudo
# (gitlab-ctl, /var/opt/gitlab et /var/log/gitlab ne sont lisibles que par root).
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Lancer avec sudo" >&2; exit 1; }

titre() { printf '\n## %s\n\n' "$*"; }

echo "# Fiche d'instance GitLab - $(hostname) - $(date '+%F %T')"

titre "Version"
echo '```'
# Version du paquet (source de vérité côté système)
head -1 /opt/gitlab/version-manifest.txt
dpkg-query -W -f='paquet ${Package} ${Version} (${Architecture})\n' gitlab-ce gitlab-ee 2>/dev/null | grep -v ' ()$' || true
apt-mark showhold 2>/dev/null | grep -E '^gitlab' | sed 's/^/version bloquée (apt-mark hold) : /' || true
# Version vue par l'application (sans jeton : /-/readiness ne la donne pas, on lit le fichier)
echo "gitlab-rails : $(cat /var/opt/gitlab/gitlab-rails/VERSION 2>/dev/null || cat /opt/gitlab/embedded/service/gitlab-rails/VERSION)"
echo "gitaly       : $(/opt/gitlab/embedded/bin/gitaly --version 2>/dev/null | head -1)"
echo "gitlab-shell : $(cat /opt/gitlab/embedded/service/gitlab-shell/VERSION)"
echo '```'

titre "Services (gitlab-ctl status)"
echo '```'
gitlab-ctl status | awk '{gsub(/[:();]/,""); printf "%-20s %-5s pid %-7s depuis %s\n", $2, $1, $4, $5}'
echo '```'

titre "Ports en écoute (processus GitLab et annexes)"
echo '```'
ss -Hltnp | awk '{split($6,a,"\""); n=split($4,p,":"); printf "%-6s %-24s %s\n", p[n], $4, a[2]}' | sort -n -k1,1 -u
echo '```'

titre "Stockage"
echo '```'
df -h /var/opt/gitlab | tail -1 | awk '{print "partition de /var/opt/gitlab : " $2 " dont " $3 " utilisés (" $5 ")"}'
du -sh /var/opt/gitlab/{git-data,postgresql,redis,gitaly,prometheus,backups} \
       /var/opt/gitlab/gitlab-rails/{uploads,shared/artifacts,shared/lfs-objects,shared/packages} 2>/dev/null
echo "dépôts (hashed storage) : $(find /var/opt/gitlab/git-data/repositories/@hashed -maxdepth 3 -name '*.git' ! -name '*.wiki.git' | wc -l) projets"
echo '```'

titre "Journaux (les 10 plus gros fichiers de /var/log/gitlab)"
echo '```'
find /var/log/gitlab -type f -printf '%s %p\n' | sort -rn | head -10 | awk '{printf "%8.1f Ko  %s\n", $1/1024, $2}'
echo '```'

titre "Configuration LDAP (gitlab.rb, mot de passe masqué)"
echo '```'
sed -n "/ldap_enabled/,/^}/p" /etc/gitlab/gitlab.rb | grep -vE '^\s*#' \
  | sed -E "s/('password' *=> *)'[^']*'/\1'********'/"
echo '```'

titre "Contrôle LDAP (gitlab-rake gitlab:ldap:check, 3 premières entrées)"
echo '```'
gitlab-rake gitlab:ldap:check 2>/dev/null | grep -E 'Server|authentication|DN:' | head -5
echo '```'
