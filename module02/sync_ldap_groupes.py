#!/opt/formation/venv/bin/python
"""Module 02 - Synchronisation groupes LDAP -> appartenances aux groupes GitLab (GitLab CE).

La synchronisation native des groupes LDAP (« LDAP group links ») est une fonction
Premium. En CE, ce script la remplace : il lit les membres des groupes LDAP (ldap3)
et applique les appartenances GitLab correspondantes par l'API REST (python-gitlab).

Usage :
    sync_ldap_groupes.py -c mapping.yml --dry-run          # simulation : rien n'est modifié
    sync_ldap_groupes.py -c mapping.yml                    # application réelle
    sync_ldap_groupes.py -c mapping.yml --create-missing   # crée aussi les comptes GitLab
                                                           # des membres LDAP autorisés jamais connectés
    options : --rapport rapport.md  --csv rapport.csv  -v

Principes :
  * idempotent : une 2e exécution sans changement LDAP ne fait aucune action ;
  * dry-run : le plan d'actions est calculé et affiché, sans aucun appel d'écriture ;
  * périmètre : seuls les membres DIRECTS des groupes GitLab possédant une identité LDAP
    (provider ldapmain) sont gérés. Comptes locaux, bots et comptes protégés sont signalés
    mais jamais modifiés ;
  * pas de dégradation d'un Owner, niveau supérieur conservé si la politique le demande ;
  * journal horodaté sur stderr, rapport Markdown/CSV, code retour 0 (OK), 1 (erreurs).

Secrets : jeton GitLab dans $GITLAB_TOKEN ou le fichier indiqué dans le mapping ;
mot de passe du compte de bind LDAP dans la variable indiquée (défaut LDAP_BIND_PASSWORD).
"""
import argparse
import csv
import datetime as dt
import logging
import os
import sys

import gitlab
import yaml
from ldap3 import Connection, Server, SUBTREE
from ldap3.utils.conv import escape_filter_chars

NIVEAUX = {"guest": 10, "planner": 15, "reporter": 20, "developer": 30, "maintainer": 40, "owner": 50}
NOMS = {v: k for k, v in NIVEAUX.items()}

log = logging.getLogger("sync-ldap")


def charger_config(chemin):
    with open(chemin, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    for cle in ("gitlab", "ldap", "mappings"):
        if cle not in cfg:
            sys.exit(f"Clé « {cle} » absente de {chemin}")
    return cfg


def connexion_gitlab(cfg):
    jeton = os.environ.get("GITLAB_TOKEN")
    if not jeton:
        with open(os.path.expanduser(cfg.get("token_file", "~/.gitlab-token")), encoding="utf-8") as f:
            jeton = f.read().strip()
    gl = gitlab.Gitlab(cfg["url"], private_token=jeton, per_page=100, retry_transient_errors=True)
    gl.auth()
    if not getattr(gl.user, "is_admin", False):
        sys.exit("Le jeton doit appartenir à un administrateur (lecture des identités LDAP).")
    return gl


def connexion_ldap(cfg):
    mdp = os.environ.get(cfg.get("password_env", "LDAP_BIND_PASSWORD"))
    if mdp is None:
        sys.exit(f"Variable {cfg.get('password_env', 'LDAP_BIND_PASSWORD')} non définie (mot de passe de bind LDAP)")
    conn = Connection(Server(cfg["url"]), user=cfg["bind_dn"], password=mdp, auto_bind=True, read_only=True)
    return conn


def membres_ldap(conn, cfg, groupe):
    """Retourne {uid: {dn, cn, mail}} des membres du groupe LDAP (overlay memberOf, comme le filtre GitLab).

    Active Directory : pour inclure les groupes imbriqués, utiliser le filtre
    (memberOf:1.2.840.113556.1.4.1941:=<dn du groupe>).
    """
    dn_groupe = f"cn={groupe},{cfg['base_groups']}"
    conn.search(cfg["base_users"], f"(memberOf={escape_filter_chars(dn_groupe)})",
                SUBTREE, attributes=["uid", "cn", "mail"])
    return {str(e.uid).lower(): {"dn": e.entry_dn, "cn": str(e.cn), "mail": str(e.mail)} for e in conn.entries}


def plan_mapping(gl, m, ldap_uids, autorises, utilisateurs, politique, create_missing, a_creer):
    """Calcule la liste des actions pour un mapping. Ne modifie rien."""
    actions = []
    niveau = NIVEAUX[m["access_level"]]
    expire = None
    if m.get("expires_in_days"):
        expire = (dt.date.today() + dt.timedelta(days=int(m["expires_in_days"]))).isoformat()
    groupe = gl.groups.get(m["gitlab_group"])
    directs = {mb.username: mb for mb in groupe.members.list(get_all=True)}
    proteges = set(politique.get("proteger", []))

    def act(usr, action, detail, **kw):
        actions.append(dict(mapping=f"{m['ldap_group']} -> {m['gitlab_group']}", groupe=groupe,
                            utilisateur=usr, action=action, detail=detail, **kw))

    # 1. Membres LDAP -> doivent être membres GitLab au bon niveau
    for uid, info in sorted(ldap_uids.items()):
        u = utilisateurs.get(uid)
        if uid not in autorises:
            act(uid, "IGNORER", "hors du groupe d'accès GitLab (filtre LDAP) : ne peut pas se connecter")
            continue
        if u is None:
            if create_missing:
                if uid not in a_creer:  # un même compte peut figurer dans plusieurs mappings
                    act(uid, "CREER_COMPTE", f"compte GitLab LDAP ({info['dn']})", ldap=info)
                    a_creer.add(uid)
                act(uid, "AJOUTER", f"{NOMS[niveau]}" + (f" jusqu'au {expire}" if expire else ""),
                    niveau=niveau, expire=expire)
            else:
                act(uid, "SIGNALER", "pas encore de compte GitLab (créé à la 1re connexion ; --create-missing pour le créer)")
            continue
        if u.state != "active":
            act(uid, "SIGNALER", f"compte GitLab {u.state} : non ajouté")
            continue
        mb = directs.get(uid)
        if mb is None:
            act(uid, "AJOUTER", f"{NOMS[niveau]}" + (f" jusqu'au {expire}" if expire else ""),
                user_id=u.id, niveau=niveau, expire=expire)
        elif mb.access_level == niveau:
            if expire and not mb.expires_at:
                act(uid, "MODIFIER", f"ajout de l'expiration au {expire}", user_id=u.id, niveau=niveau, expire=expire)
            else:
                act(uid, "CONFORME", NOMS[niveau] + (f" jusqu'au {mb.expires_at}" if mb.expires_at else ""))
        elif mb.access_level > niveau and (politique.get("conserver_niveau_superieur", True) or mb.access_level == 50):
            act(uid, "CONSERVER", f"niveau actuel {NOMS[mb.access_level]} > {NOMS[niveau]} (conservé)")
        else:
            act(uid, "MODIFIER", f"{NOMS[mb.access_level]} -> {NOMS[niveau]}", user_id=u.id, niveau=niveau, expire=expire)

    # 2. Membres directs GitLab absents du groupe LDAP
    for username, mb in sorted(directs.items()):
        if username in ldap_uids:
            continue
        u = utilisateurs.get(username)
        identites = [i["provider"] for i in (getattr(u, "identities", None) or [])] if u else []
        if username in proteges or getattr(u, "bot", False) or username.startswith(("project_", "group_")):
            continue  # comptes protégés / bots : hors périmètre, silencieux
        if "ldapmain" not in identites:
            act(username, "HORS_PERIMETRE", f"compte local {NOMS.get(mb.access_level, mb.access_level)} : non géré par la synchro (à auditer)")
        elif mb.access_level == 50:
            act(username, "SIGNALER", "Owner absent du groupe LDAP : non retiré automatiquement")
        elif politique.get("retirer_absents", True):
            act(username, "RETIRER", f"absent de {m['ldap_group']} (était {NOMS.get(mb.access_level)})", user_id=mb.id)
        else:
            act(username, "SIGNALER", f"absent de {m['ldap_group']} (retrait désactivé)")
    return actions


def appliquer(gl, a, provider):
    g = a["groupe"]
    if a["action"] == "CREER_COMPTE":
        info = a["ldap"]
        u = gl.users.create({"username": a["utilisateur"], "name": info["cn"], "email": info["mail"],
                             "provider": provider, "extern_uid": info["dn"],
                             "force_random_password": True, "skip_confirmation": True})
        return u
    elif a["action"] == "AJOUTER":
        data = {"user_id": a["user_id"], "access_level": a["niveau"]}
        if a.get("expire"):
            data["expires_at"] = a["expire"]
        g.members.create(data)
    elif a["action"] == "MODIFIER":
        mb = g.members.get(a["user_id"])
        mb.access_level = a["niveau"]
        if a.get("expire"):
            mb.expires_at = a["expire"]
        mb.save()
    elif a["action"] == "RETIRER":
        g.members.delete(a["user_id"])


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-c", "--config", required=True)
    p.add_argument("--dry-run", action="store_true", help="simulation : n'écrit rien")
    p.add_argument("--create-missing", action="store_true", help="crée les comptes GitLab LDAP manquants")
    p.add_argument("--rapport", help="fichier Markdown de rapport")
    p.add_argument("--csv", help="fichier CSV des actions")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)-7s %(message)s", stream=sys.stderr)

    cfg = charger_config(args.config)
    gl = connexion_gitlab(cfg["gitlab"])
    conn = connexion_ldap(cfg["ldap"])
    politique = cfg.get("politique", {})
    provider = cfg["ldap"].get("provider", "ldapmain")
    mode = "SIMULATION (--dry-run)" if args.dry_run else "RÉEL"
    log.info("Début de synchronisation, mode %s, %d mapping(s)", mode, len(cfg["mappings"]))

    # Comptes autorisés à se connecter : membres du groupe d'accès (même filtre que gitlab.rb)
    autorises = membres_ldap(conn, cfg["ldap"], cfg["ldap"]["groupe_acces"])
    # Tous les utilisateurs GitLab, indexés par username (une seule passe paginée)
    utilisateurs = {u.username.lower(): u for u in gl.users.list(iterator=True)}
    log.info("%d comptes autorisés dans LDAP, %d utilisateurs GitLab", len(autorises), len(utilisateurs))

    toutes, erreurs, a_creer = [], 0, set()
    for m in cfg["mappings"]:
        if m["access_level"] not in NIVEAUX:
            sys.exit(f"Niveau inconnu : {m['access_level']}")
        uids = membres_ldap(conn, cfg["ldap"], m["ldap_group"])
        log.info("Groupe LDAP %s : %d membre(s) -> %s (%s)", m["ldap_group"], len(uids),
                 m["gitlab_group"], m["access_level"])
        actions = plan_mapping(gl, m, uids, autorises, utilisateurs, politique, args.create_missing, a_creer)
        for a in actions:
            ecriture = a["action"] in ("CREER_COMPTE", "AJOUTER", "MODIFIER", "RETIRER")
            a["statut"] = "simulé" if (ecriture and args.dry_run) else ("à faire" if ecriture else "info")
            if ecriture and not args.dry_run:
                try:
                    if a["action"] == "AJOUTER" and not a.get("user_id"):
                        a["user_id"] = utilisateurs[a["utilisateur"]].id   # compte créé juste avant
                    nouveau = appliquer(gl, a, provider)
                    if nouveau is not None:
                        utilisateurs[a["utilisateur"]] = nouveau            # visible des mappings suivants
                    a["statut"] = "OK"
                except gitlab.exceptions.GitlabError as e:
                    a["statut"] = f"ERREUR {e.response_code} {e.error_message}"
                    erreurs += 1
            niveau_log = logging.WARNING if a["statut"].startswith("ERREUR") else logging.INFO
            log.log(niveau_log, "%-14s %-18s %-32s %s [%s]", a["action"], a["utilisateur"],
                    a["mapping"], a["detail"], a["statut"])
        toutes.extend(actions)

    ecritures = [a for a in toutes if a["action"] in ("CREER_COMPTE", "AJOUTER", "MODIFIER", "RETIRER")]
    log.info("Terminé : %d action(s) d'écriture %s, %d erreur(s)", len(ecritures),
             "simulée(s)" if args.dry_run else "appliquée(s)", erreurs)

    colonnes = ["mapping", "utilisateur", "action", "detail", "statut"]
    if args.rapport:
        with open(args.rapport, "w", encoding="utf-8") as f:
            f.write(f"# Rapport de synchronisation LDAP -> GitLab\n\n- Date : {dt.datetime.now():%Y-%m-%d %H:%M}\n"
                    f"- Mode : {mode}\n- Actions d'écriture : {len(ecritures)}\n- Erreurs : {erreurs}\n\n")
            f.write("| " + " | ".join(colonnes) + " |\n|" + "---|" * len(colonnes) + "\n")
            for a in toutes:
                f.write("| " + " | ".join(str(a[c]) for c in colonnes) + " |\n")
        log.info("Rapport Markdown : %s", args.rapport)
    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=colonnes, extrasaction="ignore", delimiter=";")
            w.writeheader()
            w.writerows(toutes)
        log.info("Rapport CSV : %s", args.csv)
    return 1 if erreurs else 0


if __name__ == "__main__":
    sys.exit(main())
