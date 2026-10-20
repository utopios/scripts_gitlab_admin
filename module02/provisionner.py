#!/opt/formation/venv/bin/python
"""Module 02 - Provisionnement déclaratif et idempotent (python-gitlab).

Lit un fichier YAML décrivant groupes, sous-groupes, projets et membres, et crée ou
corrige ce qui manque. Relancé sans changement, il n'effectue aucune écriture.

Usage : provisionner.py provision.yml [--dry-run]

Format :
  groupes:
    - chemin: m02-demo                 # groupe racine
      visibilite: private
      membres: {alice.martin: developer}
    - chemin: m02-demo/equipe-a        # sous-groupe (parent créé avant)
      projets: [api, front]
      membres: {bob.durand: maintainer, emma.bernard: {niveau: reporter, expire: 2026-12-31}}
"""
import argparse
import os
import sys

import gitlab
import yaml

NIVEAUX = {"guest": 10, "planner": 15, "reporter": 20, "developer": 30, "maintainer": 40, "owner": 50}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("fichier")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args()
    jeton = os.environ.get("GITLAB_TOKEN") or open(os.path.expanduser("~/.gitlab-token")).read().strip()
    gl = gitlab.Gitlab(os.environ.get("GITLAB_URL", "http://gitlab.formation.lan"), private_token=jeton)
    cfg = yaml.safe_load(open(a.fichier, encoding="utf-8"))
    ecritures, erreurs = 0, 0

    def faire(msg):
        nonlocal ecritures
        ecritures += 1
        print(("[SIMULATION] " if a.dry_run else "") + msg)
        return not a.dry_run

    for g in cfg["groupes"]:
        chemin = g["chemin"]
        try:
            groupe = gl.groups.get(chemin)
        except gitlab.exceptions.GitlabGetError:
            parent, _, nom = chemin.rpartition("/")
            data = {"name": nom, "path": nom, "visibility": g.get("visibilite", "private")}
            if not faire(f"créer le groupe {chemin}"):
                continue  # simulation : on ne peut pas décrire le contenu d'un groupe inexistant
            if parent:
                data["parent_id"] = gl.groups.get(parent).id
            groupe = gl.groups.create(data)

        for projet in g.get("projets", []):
            try:
                gl.projects.get(f"{chemin}/{projet}")
            except gitlab.exceptions.GitlabGetError:
                if faire(f"créer le projet {chemin}/{projet}"):
                    gl.projects.create({"name": projet, "path": projet, "namespace_id": groupe.id,
                                        "initialize_with_readme": True})

        actuels = {m.username: m for m in groupe.members.list(get_all=True)}
        for username, spec in (g.get("membres") or {}).items():
            spec = spec if isinstance(spec, dict) else {"niveau": spec}
            niveau, expire = NIVEAUX[spec["niveau"]], spec.get("expire")
            expire = str(expire) if expire else None
            m = actuels.get(username)
            if m is None:
                if faire(f"ajouter {username} à {chemin} ({spec['niveau']}{', expire ' + expire if expire else ''})"):
                    uid = gl.users.list(username=username)[0].id
                    data = {"user_id": uid, "access_level": niveau}
                    if expire:
                        data["expires_at"] = expire
                    try:
                        groupe.members.create(data)
                    except gitlab.exceptions.GitlabCreateError as e:
                        # ex. 400 : niveau inférieur à un niveau hérité d'un groupe parent
                        erreurs += 1
                        print(f"  ERREUR {e.response_code} : {e.error_message}")
            elif m.access_level != niveau or (m.expires_at or None) != expire:
                if faire(f"corriger {username} dans {chemin} : {m.access_level}/{m.expires_at} -> {niveau}/{expire}"):
                    m.access_level, m.expires_at = niveau, expire
                    m.save()
    print(f"{ecritures} écriture(s) {'simulée(s)' if a.dry_run else 'tentée(s)'}, {erreurs} erreur(s)")
    return 1 if erreurs else 0


if __name__ == "__main__":
    sys.exit(main())
