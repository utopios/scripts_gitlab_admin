#!/usr/bin/env bash
# Réparation de l'incident 04 : corriger le filtre, reconfigurer (Puma redémarre),
# puis vérifier avec gitlab:ldap:check que des utilisateurs sont de nouveau visibles.
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"
N=04

sed -i 's/cn=gitlab-user,ou=groups/cn=gitlab-users,ou=groups/' /etc/gitlab/gitlab.rb
reconfigurer
attendre_gitlab 300
nb=$(gitlab-rake gitlab:ldap:check 2>/dev/null | grep -c 'DN: ' || true)
log "gitlab:ldap:check : $nb utilisateur(s) LDAP autorisé(s)"
(( nb > 0 )) || die "toujours aucun utilisateur LDAP visible"
demarquer $N
log "Incident $N réparé."
