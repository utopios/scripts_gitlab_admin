#!/usr/bin/env bash
# Incident 04 — Plus aucun utilisateur LDAP ne peut se connecter
# Une « relecture » de gitlab.rb a introduit une faute dans user_filter :
# cn=gitlab-user au lieu de cn=gitlab-users. Le bind LDAP fonctionne, mais le filtre ne
# renvoie plus personne : « Invalid credentials » pour tout le monde.
# Les comptes locaux (root, prestataire.ext) continuent de fonctionner.
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"

N=04
est_injecte $N && die "incident $N déjà injecté"
grep -q 'cn=gitlab-users,ou=groups' /etc/gitlab/gitlab.rb || die "filtre attendu absent de gitlab.rb"
cp -p /etc/gitlab/gitlab.rb "$ETAT/$N-gitlab.rb.avant"
sed -i 's/cn=gitlab-users,ou=groups/cn=gitlab-user,ou=groups/' /etc/gitlab/gitlab.rb
reconfigurer
attendre_gitlab 300 || true
marquer $N
log "Incident $N injecté."
