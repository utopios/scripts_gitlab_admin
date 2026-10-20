#!/opt/formation/venv/bin/python
"""Module 03 - Audit des accès GitLab CE : rapport Markdown + CSV des écarts.

Usage :
    export LDAP_BIND_PASSWORD='...'            # compte de bind LDAP (lecture seule)
    audit_acces.py --sortie /tmp/audit         # produit /tmp/audit.md et /tmp/audit.csv
Options :
    --jours-inactivite 90   compte sans activité depuis N jours
    --jours-expiration 7    jetons / clés expirant dans moins de N jours
    --duree-max-jeton 90    durée de vie maximale admise d'un jeton (jours)
    --ignorer REGEX         exceptions acceptées (utilisateurs ou chemins), ex. '^m0[0-9]-'

Lecture seule : aucun appel d'écriture. Jeton administrateur dans $GITLAB_TOKEN ou
~/.gitlab-token. Sources : API REST (utilisateurs, appartenances, jetons, clés) et
annuaire LDAP (ldap3) pour la détection des écarts.

Niveaux : CRITIQUE (exploitable / à traiter immédiatement), ELEVE (sous 7 jours),
MOYEN (sous 30 jours), INFO (à surveiller).
"""
import argparse
import base64
import csv
import datetime as dt
import os
import re
import struct
import sys
from collections import Counter

import gitlab
from ldap3 import BASE, Connection, Server

NIV = {10: "Guest", 15: "Planner", 20: "Reporter", 30: "Developer", 40: "Maintainer", 50: "Owner"}
ORDRE = {"CRITIQUE": 0, "ELEVE": 1, "MOYEN": 2, "INFO": 3}
AUJ = dt.date.today()


def jours_avant(date_txt):
    """Nombre de jours entre aujourd'hui et une date ISO (négatif si passée)."""
    return (dt.date.fromisoformat(date_txt[:10]) - AUJ).days if date_txt else None


def taille_rsa(cle):
    """Taille en bits d'une clé publique ssh-rsa (lecture du module dans le blob)."""
    try:
        blob = base64.b64decode(cle.split()[1])
        champs, i = [], 0
        while i < len(blob):
            n = struct.unpack(">I", blob[i:i + 4])[0]
            champs.append(blob[i + 4:i + 4 + n])
            i += 4 + n
        module = champs[2].lstrip(b"\x00")
        return len(module) * 8
    except Exception:
        return None


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default=os.environ.get("GITLAB_URL", "http://gitlab.formation.lan"))
    p.add_argument("--ldap-url", default="ldap://127.0.0.1:389")
    p.add_argument("--bind-dn", default="cn=gitlab-bind,ou=services,dc=formation,dc=lan")
    p.add_argument("--groupe-acces", default="cn=gitlab-users,ou=groups,dc=formation,dc=lan")
    p.add_argument("--sortie", default="rapport-audit")
    p.add_argument("--jours-inactivite", type=int, default=90)
    p.add_argument("--jours-expiration", type=int, default=7)
    p.add_argument("--duree-max-jeton", type=int, default=90)
    p.add_argument("--ignorer", help="regex des utilisateurs/chemins exclus (exceptions acceptées)")
    a = p.parse_args()
    ignore = re.compile(a.ignorer) if a.ignorer else None

    def exclu(*noms):
        return bool(ignore) and any(n and ignore.search(n) for n in noms)

    jeton = os.environ.get("GITLAB_TOKEN") or open(os.path.expanduser("~/.gitlab-token")).read().strip()
    gl = gitlab.Gitlab(a.url, private_token=jeton, per_page=100, retry_transient_errors=True)
    mdp = os.environ.get("LDAP_BIND_PASSWORD")
    if mdp is None:
        sys.exit("Définir LDAP_BIND_PASSWORD (mot de passe du compte de bind LDAP)")
    ldap = Connection(Server(a.ldap_url), user=a.bind_dn, password=mdp, auto_bind=True, read_only=True)

    ecarts = []

    def ecart(niveau, categorie, objet, constat, reco):
        ecarts.append(dict(criticite=niveau, categorie=categorie, objet=objet, constat=constat, recommandation=reco))

    # ------------------------------------------------------------------ utilisateurs
    users = {u.id: u for u in gl.users.list(iterator=True)}
    humains = {i: u for i, u in users.items() if not u.bot and u.username != "ghost" and not exclu(u.username)}
    actifs = {i: u for i, u in humains.items() if u.state == "active"}
    kpi = Counter()
    kpi["utilisateurs humains"] = len(humains)
    kpi["actifs"] = len(actifs)
    kpi["bloqués / ldap_blocked / désactivés"] = len(humains) - len(actifs)

    jamais, hors_ldap = [], set()
    for u in actifs.values():
        idents = {i["provider"]: i["extern_uid"] for i in (u.identities or [])}
        derniere = u.last_activity_on
        if u.is_admin:
            kpi["administrateurs"] += 1
        if u.two_factor_enabled:
            kpi["avec 2FA"] += 1
        if u.external:
            kpi["externes"] += 1
        if "ldapmain" not in idents:
            kpi["comptes locaux (hors root)"] += u.username != "root"
        # Administrateurs
        if u.is_admin and u.username != "root" and "ldapmain" not in idents:
            ecart("CRITIQUE", "Administrateur", u.username,
                  "administrateur avec un compte local (hors annuaire, non soumis au cycle de vie LDAP)",
                  "retirer le droit admin ou rattacher à LDAP (gitlab-admins) ; bloquer si inutilisé")
        if u.is_admin and not u.two_factor_enabled:
            ecart("ELEVE", "Administrateur", u.username, "administrateur sans 2FA",
                  "imposer la 2FA aux administrateurs (require_admin_two_factor_authentication)")
        # Inactivité
        if derniere is None:
            jamais.append(u.username)
        elif jours_avant(derniere) < -a.jours_inactivite:
            ecart("MOYEN", "Inactivité", u.username, f"inactif depuis le {derniere}",
                  "désactiver (deactivate) ou activer deactivate_dormant_users")
        # Écart avec l'annuaire
        if "ldapmain" in idents:
            dn = idents["ldapmain"]
            ok = ldap.search(dn, "(objectClass=*)", BASE, attributes=["memberOf"])
            if not ok:
                hors_ldap.add(u.username)
                ecart("CRITIQUE", "Écart LDAP", u.username, f"actif dans GitLab mais absent de l'annuaire ({dn})",
                      "bloquer immédiatement, révoquer jetons et clés (offboarding)")
            else:
                groupes = [str(g).lower() for g in ldap.entries[0].memberOf] if "memberOf" in ldap.entries[0] else []
                if a.groupe_acces.lower() not in groupes:
                    hors_ldap.add(u.username)
                    ecart("CRITIQUE", "Écart LDAP", u.username,
                          "actif dans GitLab mais hors du groupe d'accès LDAP (départ / désactivation)",
                          "bloquer (offboarding) ; CE ne bloque qu'à la prochaine connexion ou opération Git")
    if jamais:
        ecart("INFO", "Inactivité", f"{len(jamais)} comptes", "jamais connectés : " + ", ".join(sorted(jamais)),
              "vérifier le besoin ; bloquer/désactiver les comptes inutilisés")
    kpi["sans 2FA"] = len(actifs) - kpi["avec 2FA"]
    if kpi["sans 2FA"]:
        ecart("MOYEN", "Authentification", f"{kpi['sans 2FA']} comptes", "comptes actifs sans 2FA",
              "rendre la 2FA obligatoire (require_two_factor_authentication) ou via le fournisseur d'identité")

    # ------------------------------------------------------------------ droits (membres directs)
    def controler_membre(chemin, m):
        u = users.get(m.id)
        if not u or u.bot or exclu(u.username):
            return
        if m.access_level == 50 and u.username != "root":
            kpi["appartenances Owner (hors root)"] += 1
        if u.external and m.access_level >= 40:
            ecart("CRITIQUE", "Droits", f"{u.username} @ {chemin}",
                  f"utilisateur externe {NIV[m.access_level]} (gère membres, jetons, paramètres)",
                  "ramener à Developer/Reporter, fixer une date d'expiration de l'appartenance")
        if u.state != "active":
            ecart("MOYEN", "Droits", f"{u.username} @ {chemin}",
                  f"compte {u.state} toujours membre {NIV[m.access_level]}", "retirer l'appartenance")
        elif (m.access_level >= 40 and not getattr(m, "expires_at", None) and not u.is_admin and not u.external
              and "ldapmain" not in {i["provider"] for i in (u.identities or [])}):
            ecart("ELEVE", "Droits", f"{u.username} @ {chemin}",
                  f"compte local {NIV[m.access_level]} sans expiration (compte de service « humain » ?)",
                  "remplacer par un jeton de groupe/projet ; sinon documenter un responsable")

    for g in gl.groups.list(iterator=True, all_available=True):
        if not exclu(g.full_path):
            for m in g.members.list(get_all=True):
                controler_membre(g.full_path, m)
    for prj in gl.projects.list(iterator=True, simple=True):
        if not exclu(prj.path_with_namespace):
            for m in gl.projects.get(prj.id, lazy=True).members.list(get_all=True):
                controler_membre(prj.path_with_namespace, m)

    # ------------------------------------------------------------------ jetons
    pats = list(gl.personal_access_tokens.list(state="active", iterator=True))
    for t in pats:
        u = users.get(t.user_id)
        nom = u.username if u else str(t.user_id)
        if exclu(nom, t.name):
            continue
        kpi["jetons actifs (PAT + groupe/projet)"] += 1
        if nom in hors_ldap:
            ecart("CRITIQUE", "Jetons", f"jeton « {t.name} » ({nom})",
                  f"jeton valide ({','.join(t.scopes)}) d'un compte sorti de l'annuaire", "révoquer immédiatement")
        objet = f"jeton « {t.name} » ({nom})"
        restant = jours_avant(t.expires_at)
        duree = (dt.date.fromisoformat(t.expires_at) - dt.date.fromisoformat(t.created_at[:10])).days if t.expires_at else None
        if {"sudo", "admin_mode"} & set(t.scopes) and nom != "root":
            ecart("CRITIQUE", "Jetons", objet, f"scopes {','.join(t.scopes)} sur un compte non root",
                  "révoquer ; jetons sudo/admin_mode réservés à un compte d'administration nominatif, durée courte")
        elif {"sudo", "admin_mode"} & set(t.scopes):
            ecart("ELEVE", "Jetons", objet, f"jeton root {','.join(t.scopes)}, valable {duree} jours",
                  "réduire les scopes et la durée ; stocker dans un coffre ; rotation")
        if u and u.state != "active":
            ecart("ELEVE", "Jetons", objet, f"jeton actif d'un compte {u.state}", "révoquer")
        if restant is not None and 0 <= restant <= a.jours_expiration:
            ecart("MOYEN", "Jetons", objet, f"expire dans {restant} jour(s) ({t.expires_at})",
                  "prévenir le propriétaire ; rotation (POST /personal_access_tokens/:id/rotate)")
        if duree and duree > a.duree_max_jeton and "api" in t.scopes and not u.bot \
                and not {"sudo", "admin_mode"} & set(t.scopes):
            ecart("ELEVE", "Jetons", objet, f"scope api valable {duree} jours (> {a.duree_max_jeton})",
                  "réduire la durée (max_personal_access_token_lifetime est Premium : contrôle par audit)")
        if t.last_used_at is None:
            kpi["jetons jamais utilisés"] += 1
    # Jetons de groupe/projet : les bots associés apparaissent dans la liste ci-dessus
    for t in pats:
        u = users.get(t.user_id)
        if u and u.bot and not exclu(u.username, t.name):
            duree = (dt.date.fromisoformat(t.expires_at) - dt.date.fromisoformat(t.created_at[:10])).days
            if "api" in t.scopes and duree > 180:
                ecart("MOYEN", "Jetons", f"jeton de groupe/projet « {t.name} » ({u.username})",
                      f"scope api valable {duree} jours", "limiter le scope (read_api, read_repository) et la durée")

    # ------------------------------------------------------------------ clés de déploiement / jetons de déploiement
    for k in gl.http_list("/deploy_keys", get_all=True):   # endpoint admin : toutes les clés
        kpi["clés de déploiement"] += 1
        for prj in k["projects_with_write_access"]:
            if exclu(prj["path_with_namespace"]):
                continue
            ecart("ELEVE", "Clés de déploiement", f"« {k['title']} » @ {prj['path_with_namespace']}",
                  "clé de déploiement avec droit d'écriture (push)" + ("" if k["expires_at"] else ", sans expiration"),
                  "passer en lecture seule si possible ; sinon branches protégées + expiration")
    try:
        for d in gl.http_list("/deploy_tokens", get_all=True):
            if not d.get("expired") and not d.get("revoked"):
                kpi["jetons de déploiement actifs"] += 1
                if "write_repository" in d["scopes"] or "write_registry" in d["scopes"]:
                    ecart("MOYEN", "Jetons de déploiement", d["name"], f"scopes {','.join(d['scopes'])}",
                          "vérifier le besoin d'écriture ; fixer une expiration")
    except gitlab.exceptions.GitlabError:
        pass

    # ------------------------------------------------------------------ clés SSH
    for u in humains.values():
        for k in gl.http_list(f"/users/{u.id}/keys", get_all=True):
            kpi["clés SSH"] += 1
            objet = f"clé SSH « {k['title']} » ({u.username})"
            restant = jours_avant(k.get("expires_at"))
            if k["key"].startswith("ssh-rsa") and (taille_rsa(k["key"]) or 0) < 3072:
                ecart("MOYEN", "Clés SSH", objet, f"RSA {taille_rsa(k['key'])} bits",
                      "remplacer par ed25519 ; restreindre (Admin > Paramètres > Restrictions de clés SSH)")
            if restant is not None and 0 <= restant <= a.jours_expiration:
                ecart("MOYEN", "Clés SSH", objet, f"expire dans {restant} jour(s)", "prévenir le propriétaire")
            if k.get("expires_at") is None:
                kpi["clés SSH sans expiration"] += 1
            if u.state != "active":
                ecart("MOYEN", "Clés SSH", objet, f"clé d'un compte {u.state}", "supprimer")
            if u.username in hors_ldap:
                ecart("CRITIQUE", "Clés SSH", objet, "clé valide d'un compte sorti de l'annuaire",
                      "supprimer la clé et bloquer le compte")

    # ------------------------------------------------------------------ sorties
    ecarts.sort(key=lambda e: (ORDRE[e["criticite"]], e["categorie"], e["objet"]))
    par_niveau = Counter(e["criticite"] for e in ecarts)
    colonnes = ["criticite", "categorie", "objet", "constat", "recommandation"]
    with open(f"{a.sortie}.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=colonnes, delimiter=";")
        w.writeheader()
        w.writerows(ecarts)
    with open(f"{a.sortie}.md", "w", encoding="utf-8") as f:
        f.write(f"# Rapport d'audit des accès GitLab\n\n- Instance : {a.url} (GitLab {gl.version()[0]})\n"
                f"- Date : {dt.datetime.now():%Y-%m-%d %H:%M}\n- Exceptions exclues : {a.ignorer or 'aucune'}\n\n")
        f.write("## Synthèse\n\n| Criticité | Nombre |\n|---|---|\n")
        for n in ORDRE:
            f.write(f"| {n} | {par_niveau.get(n, 0)} |\n")
        f.write("\n## Indicateurs\n\n| Indicateur | Valeur |\n|---|---|\n")
        for k, v in kpi.items():
            f.write(f"| {k} | {v} |\n")
        if actifs:
            f.write(f"| taux de 2FA | {100 * kpi['avec 2FA'] // len(actifs)} % |\n")
        f.write("\n## Écarts\n\n| Criticité | Catégorie | Objet | Constat | Recommandation |\n|---|---|---|---|---|\n")
        for e in ecarts:
            f.write("| " + " | ".join(e[c] for c in colonnes) + " |\n")
    print(f"{len(ecarts)} écarts : " + ", ".join(f"{n} {par_niveau.get(n, 0)}" for n in ORDRE))
    print(f"Rapports : {a.sortie}.md  {a.sortie}.csv")
    return 2 if par_niveau.get("CRITIQUE") else 0


if __name__ == "__main__":
    sys.exit(main())
