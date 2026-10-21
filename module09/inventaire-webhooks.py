#!/opt/formation/venv/bin/python
"""Inventaire des webhooks et intégrations de l'instance (module 09) - python-gitlab.

Liste les system hooks, puis pour chaque projet ses webhooks (URL, événements, jeton secret,
signature, SSL, état d'auto-désactivation) et ses intégrations actives (Jenkins, Slack...).
Signale les points à corriger : pas de jeton secret, vérification SSL désactivée, URL en http://
hors réseau local, hook désactivé.
Jeton : GITLAB_TOKEN ou ~/.gitlab-token (admin requis pour les system hooks et tous les projets).
Usage : ./inventaire-webhooks.py [--json]
"""
import json, os, sys
from pathlib import Path
import gitlab
from tabulate import tabulate

URL = os.environ.get("GITLAB_URL", "http://gitlab.formation.lan")
TOKEN = os.environ.get("GITLAB_TOKEN") or Path("~/.gitlab-token").expanduser().read_text().strip()
gl = gitlab.Gitlab(URL, private_token=TOKEN, per_page=100)

EVENTS = ["push_events", "tag_push_events", "merge_requests_events", "issues_events", "note_events",
          "pipeline_events", "job_events", "deployment_events", "releases_events", "repository_update_events"]


def remarques(h) -> str:
    r = []
    if not getattr(h, "token_present", False):
        r.append("pas de jeton secret")
    if not getattr(h, "enable_ssl_verification", True):
        r.append("SSL non vérifié")
    if h.url.startswith("http://") and not any(x in h.url for x in ("127.0.0.1", "localhost", ".lan", "10.", "192.168.")):
        r.append("http en clair")
    if getattr(h, "alert_status", "executable") != "executable":
        r.append(f"ÉTAT {h.alert_status}")
    return ", ".join(r) or "ok"


rows = []
for h in gl.hooks.list(iterator=True):                      # system hooks (admin)
    ev = [e.replace("_events", "") for e in EVENTS if getattr(h, e, False)]
    rows.append(["(instance)", "system hook", h.url, ",".join(ev), remarques(h)])
for p in gl.projects.list(iterator=True, archived=False):
    for h in p.hooks.list(iterator=True):
        ev = [e.replace("_events", "") for e in EVENTS if getattr(h, e, False)]
        rows.append([p.path_with_namespace, "webhook", h.url, ",".join(ev), remarques(h)])
    for i in p.integrations.list(iterator=True):            # intégrations actives seulement
        if i.active:
            props = getattr(p.integrations.get(i.slug), "properties", None) or {}
            cible = props.get("jenkins_url") or props.get("webhook") or props.get("url") or "-"
            rows.append([p.path_with_namespace, f"intégration {i.slug}", cible,
                         ",".join(e.replace("_events", "") for e in EVENTS[:3] if getattr(i, e, False)), "-"])

if "--json" in sys.argv:
    print(json.dumps([dict(zip(["projet", "type", "url", "evenements", "remarques"], r)) for r in rows], ensure_ascii=False, indent=1))
else:
    print(tabulate(rows, headers=["projet", "type", "url", "événements", "remarques"]))
    print(f"\n{len(rows)} entrées - {sum(1 for r in rows if r[4] not in ('ok', '-'))} à examiner")
