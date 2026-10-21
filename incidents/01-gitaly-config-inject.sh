#!/usr/bin/env bash
# Incident 01 — Gitaly en boucle de redémarrage
# Simule une modification manuelle de /var/opt/gitlab/gitaly/config.toml (fichier GÉNÉRÉ
# par « gitlab-ctl reconfigure ») : le chemin du stockage « default » pointe vers un
# répertoire inexistant. Gitaly refuse de démarrer, runit le relance en boucle.
# Symptômes : erreurs 500/503 sur tout ce qui touche aux dépôts (navigation, clone, push).
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"

N=01
CONF=/var/opt/gitlab/gitaly/config.toml
est_injecte $N && die "incident $N déjà injecté"

cp -p "$CONF" "$ETAT/$N-config.toml.avant"
sed -i 's#^path = "/var/opt/gitlab/git-data/repositories"#path = "/var/opt/gitlab/git-data/repositories-new"#' "$CONF"
grep -q 'repositories-new' "$CONF" || die "motif non trouvé dans $CONF"
gitlab-ctl restart gitaly >/dev/null 2>&1 || true
marquer $N
log "Incident $N injecté."
