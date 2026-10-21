#!/opt/formation/venv/bin/python
"""
Module 06 - TP « Mise en place d'un tableau de bord »
Importe un tableau de bord Grafana (JSON) par l'API, puis PROUVE qu'il affiche des
données : chaque requête de chaque panneau est rejouée via POST /api/ds/query (comme
le fait le navigateur) et on compte les séries / points / lignes renvoyés.

Usage :
  ./importer_tableau.py [fichier.json] [--dossier "M06 Exploitation"] [--verifier-seulement]
Variables : GRAFANA_URL (défaut http://localhost:3000), GRAFANA_USER / GRAFANA_PASSWORD
            (défaut admin / Formation2026!) ou GRAFANA_TOKEN (jeton de compte de service).
Code retour : 0 si tous les panneaux renvoient des données, 1 sinon.
"""
import argparse
import json
import os
import sys
import time

import requests

URL = os.environ.get("GRAFANA_URL", "http://localhost:3000")
S = requests.Session()
if os.environ.get("GRAFANA_TOKEN"):
    S.headers["Authorization"] = f"Bearer {os.environ['GRAFANA_TOKEN']}"
else:
    S.auth = (os.environ.get("GRAFANA_USER", "admin"), os.environ.get("GRAFANA_PASSWORD", "Formation2026!"))


def ensure_folder(title, uid):
    r = S.get(f"{URL}/api/folders/{uid}")
    if r.status_code == 200:
        return uid
    r = S.post(f"{URL}/api/folders", json={"uid": uid, "title": title})
    r.raise_for_status()
    return r.json()["uid"]


def query_panel(panel, frm="now-1h", to="now"):
    """Rejoue les requêtes d'un panneau ; renvoie (nb séries, nb points/lignes, erreurs)."""
    queries = []
    for t in panel.get("targets", []):
        q = dict(t)
        q.setdefault("datasource", panel["datasource"])
        q["maxDataPoints"] = 200
        q["intervalMs"] = 30000
        if q["datasource"]["type"] == "loki" and panel["type"] == "logs":
            q["queryType"] = "range"
            q["maxLines"] = 50
        queries.append(q)
    r = S.post(f"{URL}/api/ds/query", json={"queries": queries, "from": frm, "to": to})
    series, points, errors = 0, 0, []
    for ref, res in r.json().get("results", {}).items():
        if res.get("error"):
            errors.append(f"{ref}: {res['error']}")
        for fr in res.get("frames", []):
            values = fr.get("data", {}).get("values", [])
            n = len(values[0]) if values else 0
            if n:
                series += 1
                points += n
    return series, points, errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fichier", nargs="?", default=os.path.join(os.path.dirname(__file__), "tableau-exploitation-gitlab.json"))
    ap.add_argument("--dossier", default="M06 Exploitation")
    ap.add_argument("--dossier-uid", default="m06-exploitation")
    ap.add_argument("--verifier-seulement", action="store_true")
    args = ap.parse_args()

    dash = json.load(open(args.fichier, encoding="utf-8"))
    print(f"Grafana {S.get(f'{URL}/api/health').json()['version']}")
    if not args.verifier_seulement:
        folder = ensure_folder(args.dossier, args.dossier_uid)
        dash.pop("id", None)   # l'id interne est attribué par l'instance cible
        r = S.post(f"{URL}/api/dashboards/db", json={
            "dashboard": dash, "folderUid": folder, "overwrite": True,
            "message": "Import TP module 06"})
        r.raise_for_status()
        res = r.json()
        print(f"import : {res['status']} uid={res['uid']} version={res['version']} url={URL}{res['url']}")
        time.sleep(1)

    # Relecture depuis Grafana (on vérifie ce qui est réellement stocké)
    stored = S.get(f"{URL}/api/dashboards/uid/{dash['uid']}").json()["dashboard"]
    ok = True
    print(f"\n{'panneau':<48} {'type':<11} {'séries':>6} {'points':>7}  état")
    for p in stored["panels"]:
        if p["type"] == "row":
            print(f"--- {p['title']}")
            continue
        series, points, errors = query_panel(p)
        state = "OK" if series and not errors else ("ERREUR " + "; ".join(errors) if errors else "VIDE")
        ok &= state == "OK"
        print(f"{p['title'][:47]:<48} {p['type']:<11} {series:>6} {points:>7}  {state}")
    print("\nRÉSULTAT :", "tous les panneaux renvoient des données" if ok else "au moins un panneau sans données")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
