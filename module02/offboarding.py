#!/opt/formation/venv/bin/python
"""Module 02 - Départ d'un collaborateur (offboarding) dans GitLab CE.

Usage :
    offboarding.py <username> --dry-run      # affiche ce qui serait fait
    offboarding.py <username>                # applique
    options : --garder-cles (ne supprime pas les clés SSH)  --rapport fichier.md

Actions, dans cet ordre (chacune est idempotente) :
  1. bloquer le compte (state=blocked) : plus de connexion web, API ni Git.
     Un blocage administrateur n'est PAS levé par la vérification LDAP, contrairement
     à l'état ldap_blocked (levé automatiquement si le compte revient dans le filtre) ;
  2. retirer toutes les appartenances directes (groupes et projets) ;
  3. révoquer les jetons d'accès personnels actifs ;
  4. supprimer les clés SSH (sauf --garder-cles).
Le compte n'est pas supprimé : ses contributions, son historique et la traçabilité
restent intacts (la suppression est une décision distincte, après délai de rétention).

Jeton administrateur : $GITLAB_TOKEN ou ~/.gitlab-token.
"""
import argparse
import datetime as dt
import logging
import os
import sys

import gitlab

log = logging.getLogger("offboarding")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("username")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--garder-cles", action="store_true")
    p.add_argument("--rapport")
    p.add_argument("--url", default=os.environ.get("GITLAB_URL", "http://gitlab.formation.lan"))
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s", stream=sys.stderr)

    jeton = os.environ.get("GITLAB_TOKEN") or open(os.path.expanduser("~/.gitlab-token")).read().strip()
    gl = gitlab.Gitlab(args.url, private_token=jeton, retry_transient_errors=True)
    users = gl.users.list(username=args.username)
    if not users:
        sys.exit(f"Utilisateur {args.username} introuvable")
    u = gl.users.get(users[0].id)
    if u.username == "root" or getattr(u, "bot", False):
        sys.exit("Refus : compte root ou bot")
    pref = "[SIMULATION] " if args.dry_run else ""
    lignes = []

    def trace(action, detail, statut):
        lignes.append((action, detail, statut))
        log.info("%s%-10s %-45s %s", pref, action, detail, statut)

    # 1. Blocage
    if u.state in ("blocked", "ldap_blocked"):
        trace("BLOQUER", f"état actuel {u.state}", "déjà fait")
    else:
        avant = u.state
        if not args.dry_run:
            u.block()
        trace("BLOQUER", f"état {avant} -> blocked", "simulé" if args.dry_run else "OK")

    # 2. Appartenances directes (endpoint admin /users/:id/memberships)
    #    Retirer d'un groupe retire aussi, par défaut, les appartenances directes aux
    #    sous-groupes et projets de ce groupe (skip_subresources=false) : 404 ensuite = déjà fait.
    for m in gl.http_list(f"/users/{u.id}/memberships", get_all=True):
        cible = "groups" if m["source_type"] == "Namespace" else "projects"
        detail = f"{m['source_type']} {m['source_name']} (id {m['source_id']}, niveau {m['access_level']})"
        try:
            if not args.dry_run:
                gl.http_delete(f"/{cible}/{m['source_id']}/members/{u.id}")
            trace("RETIRER", detail, "simulé" if args.dry_run else "OK")
        except gitlab.exceptions.GitlabError as e:  # ex. dernier Owner d'un groupe
            if e.response_code == 404:
                trace("RETIRER", detail, "déjà retiré (cascade depuis le groupe parent)")
                continue
            trace("RETIRER", detail, f"ERREUR {e.response_code} {e.error_message}")

    # 3. Jetons personnels actifs
    for t in gl.personal_access_tokens.list(user_id=u.id, state="active", get_all=True):
        detail = f"PAT « {t.name} » scopes={','.join(t.scopes)} expire={t.expires_at}"
        if not args.dry_run:
            gl.personal_access_tokens.delete(t.id)
        trace("REVOQUER", detail, "simulé" if args.dry_run else "OK")

    # 4. Clés SSH
    if not args.garder_cles:
        for k in u.keys.list(get_all=True):
            detail = f"clé SSH « {k.title} » (id {k.id})"
            if not args.dry_run:
                u.keys.delete(k.id)
            trace("SUPPR_CLE", detail, "simulé" if args.dry_run else "OK")

    if len(lignes) == 1 and lignes[0][2] == "déjà fait":
        log.info("Rien d'autre à faire : offboarding déjà complet")
    if args.rapport:
        with open(args.rapport, "w", encoding="utf-8") as f:
            f.write(f"# Offboarding {u.username}\n\n- Date : {dt.datetime.now():%Y-%m-%d %H:%M}\n"
                    f"- Mode : {'simulation' if args.dry_run else 'réel'}\n\n| action | détail | statut |\n|---|---|---|\n")
            for a, d, s in lignes:
                f.write(f"| {a} | {d} | {s} |\n")
    return 1 if any(s.startswith("ERREUR") for _, _, s in lignes) else 0


if __name__ == "__main__":
    sys.exit(main())
