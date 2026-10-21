#!/opt/formation/venv/bin/python
"""
Module 06 - TP : alerte Grafana (Grafana-managed alert) reliée au tableau de bord.

  ./alerte_grafana.py creer       point de contact webhook + règle « M06 - Rafale de 404 »
  ./alerte_grafana.py declencher  génère des 404 et suit l'état de la règle jusqu'à firing,
                                  puis vérifie la réception de la notification
  ./alerte_grafana.py supprimer   supprime la règle et le point de contact

Prérequis : tableau importé (importer_tableau.py, dossier uid m06-exploitation) et
récepteur webhook lancé :  ./recepteur_webhook.py 9097 /tmp/m06-webhook.log &
L'en-tête « X-Disable-Provenance: true » laisse la règle modifiable dans l'UI.
"""
import os
import subprocess
import sys
import time

import requests

URL = os.environ.get("GRAFANA_URL", "http://localhost:3000")
S = requests.Session()
S.auth = (os.environ.get("GRAFANA_USER", "admin"), os.environ.get("GRAFANA_PASSWORD", "Formation2026!"))
S.headers["X-Disable-Provenance"] = "true"
FOLDER, GROUP, DASH, PANEL = "m06-exploitation", "m06-tp", "m06-exploitation-gitlab", 9
CP_NAME, RULE_UID = "m06-webhook", "m06-rafale-404"
WEBHOOK_LOG = "/tmp/m06-webhook.log"
EXPR = 'sum(rate(gitlab_workhorse_http_requests_total{code="404"}[1m]))'


def creer():
    cps = S.get(f"{URL}/api/v1/provisioning/contact-points", params={"name": CP_NAME}).json()
    if not cps:
        r = S.post(f"{URL}/api/v1/provisioning/contact-points", json={
            "name": CP_NAME, "type": "webhook",
            "settings": {"url": "http://127.0.0.1:9097/grafana", "httpMethod": "POST"}})
        r.raise_for_status()
    print("point de contact :", CP_NAME)

    rule = {
        "uid": RULE_UID, "title": "M06 - Rafale de 404", "ruleGroup": GROUP, "folderUID": FOLDER,
        "condition": "C", "for": "30s", "noDataState": "OK", "execErrState": "Error",
        "labels": {"severity": "info", "equipe": "exploitation"},
        "annotations": {"summary": 'Rafale de 404 sur GitLab : {{ printf "%.1f" $values.B.Value }} req/s',
                        "__dashboardUid__": DASH, "__panelId__": str(PANEL)},
        "data": [
            {"refId": "A", "relativeTimeRange": {"from": 300, "to": 0}, "datasourceUid": "prometheus-gitlab",
             "model": {"refId": "A", "expr": EXPR, "instant": True}},
            {"refId": "B", "datasourceUid": "__expr__",
             "model": {"refId": "B", "type": "reduce", "expression": "A", "reducer": "last"}},
            {"refId": "C", "datasourceUid": "__expr__",
             "model": {"refId": "C", "type": "threshold", "expression": "B",
                       "conditions": [{"evaluator": {"type": "gt", "params": [2]}}]}},
        ],
        # routage simplifié : la règle désigne directement son point de contact
        "notification_settings": {"receiver": CP_NAME, "group_wait": "10s", "group_interval": "1m"},
    }
    r = S.get(f"{URL}/api/v1/provisioning/alert-rules/{RULE_UID}")
    r = (S.put(f"{URL}/api/v1/provisioning/alert-rules/{RULE_UID}", json=rule) if r.status_code == 200
         else S.post(f"{URL}/api/v1/provisioning/alert-rules", json=rule))
    if r.status_code >= 300:
        sys.exit(f"échec création de la règle : {r.status_code} {r.text}")
    # intervalle d'évaluation du groupe : 10 s (défaut 1 min)
    grp = S.get(f"{URL}/api/v1/provisioning/folder/{FOLDER}/rule-groups/{GROUP}").json()
    grp["interval"] = 10
    S.put(f"{URL}/api/v1/provisioning/folder/{FOLDER}/rule-groups/{GROUP}", json=grp).raise_for_status()
    print(f"règle : {rule['title']} (uid {RULE_UID}), groupe {GROUP} évalué toutes les 10 s")


def state():
    data = S.get(f"{URL}/api/prometheus/grafana/api/v1/rules").json()
    for g in data["data"]["groups"]:
        for r in g["rules"]:
            if r.get("uid") == RULE_UID or r["name"] == "M06 - Rafale de 404":
                return r["state"], r.get("health")
    return "absente", None


def declencher():
    print("état initial :", *state())
    gen = subprocess.Popen(["bash", "-c",
        "for i in $(seq 1 900); do curl -s -o /dev/null -H 'Host: gitlab.formation.lan' "
        "http://127.0.0.1/api/v4/projects/m06-grafana-$i; sleep 0.15; done"])
    t0 = time.time()
    try:
        while time.time() - t0 < 240:
            time.sleep(10)
            st, health = state()
            print(f"  t+{int(time.time() - t0):3d}s  règle={st} ({health})")
            if st == "firing" and os.path.exists(WEBHOOK_LOG) and "Grafana" in open(WEBHOOK_LOG).read():
                break
    finally:
        gen.terminate()
    print("\nnotifications reçues par le webhook :")
    if os.path.exists(WEBHOOK_LOG):
        print("".join(l for l in open(WEBHOOK_LOG) if "Grafana" in l))


def supprimer():
    S.delete(f"{URL}/api/v1/provisioning/alert-rules/{RULE_UID}")
    for cp in S.get(f"{URL}/api/v1/provisioning/contact-points", params={"name": CP_NAME}).json():
        S.delete(f"{URL}/api/v1/provisioning/contact-points/{cp['uid']}")
    print("règle et point de contact supprimés")


if __name__ == "__main__":
    {"creer": creer, "declencher": declencher, "supprimer": supprimer}[sys.argv[1] if len(sys.argv) > 1 else "creer"]()
