#!/usr/bin/env python3
"""Récepteur de webhooks GitLab minimal (module 09) - bibliothèque standard uniquement.

- Vérifie le jeton secret (en-tête X-Gitlab-Token) en temps constant : 401 sinon.
- Vérifie la signature HMAC "webhook-signature" (format Standard Webhooks, GitLab 18.x+) si un
  jeton de signature whsec_... est fourni : HMAC-SHA256(clé, "<webhook-id>.<webhook-timestamp>.<corps>").
  Refuse aussi les messages trop anciens (rejeu) : tolérance 5 min.
- Ignore les doublons (même webhook-id / Idempotency-Key : redélivrance, nouvelle tentative).
- Journalise chaque appel en JSON Lines (une ligne par événement) et répond vite (GitLab coupe à 10 s
  par défaut : gitlab_rails['webhook_timeout']) - tout traitement long doit être asynchrone.

Usage :
  WEBHOOK_SECRET=... [WEBHOOK_SIGNING_TOKEN=whsec_...] \\
    /opt/formation/venv/bin/python webhook-receiver.py [--port 8095] [--log ~/m09-webhooks/events.jsonl]
"""
import argparse, base64, hashlib, hmac, json, os, sys, time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock

TOLERANCE_S = 300
SECRET = os.environ.get("WEBHOOK_SECRET", "")
SIGNING = os.environ.get("WEBHOOK_SIGNING_TOKEN", "")
seen_ids, lock = set(), Lock()


def verify_signature(headers, body: bytes) -> str:
    """Retourne '' si OK (ou pas de clé configurée), sinon le motif du refus."""
    if not SIGNING:
        return ""
    msg_id, ts, sig = (headers.get(h, "") for h in ("webhook-id", "webhook-timestamp", "webhook-signature"))
    if not (msg_id and ts and sig):
        return "signature absente"
    if abs(time.time() - int(ts)) > TOLERANCE_S:
        return "horodatage hors tolérance (rejeu ?)"
    key = base64.b64decode(SIGNING.removeprefix("whsec_"))
    expected = base64.b64encode(hmac.new(key, f"{msg_id}.{ts}.".encode() + body, hashlib.sha256).digest()).decode()
    # l'en-tête peut contenir plusieurs signatures "v1,xxx v1,yyy" (rotation de clé)
    if any(hmac.compare_digest(s.split(",", 1)[-1], expected) for s in sig.split()):
        return ""
    return "signature invalide"


def summary(event: str, p: dict) -> dict:
    """Champs utiles selon le type d'événement (project hook ou system hook)."""
    kind = p.get("object_kind") or p.get("event_name")
    proj = ((p.get("project") or {}).get("path_with_namespace") or p.get("path_with_namespace")
            or p.get("project_path_with_namespace"))
    user = p.get("user_username") or (p.get("user") or {}).get("username") or p.get("username")
    out = {"kind": kind, "event_name": p.get("event_name"), "project": proj, "user": user}
    if p.get("ref"):
        out["ref"] = p["ref"]
    if kind == "merge_request":
        oa = p.get("object_attributes", {})
        out.update(mr=oa.get("iid"), action=oa.get("action"))
    return {k: v for k, v in out.items() if v is not None}


class Handler(BaseHTTPRequestHandler):
    server_version = "m09-webhook-receiver/1.0"

    def _reply(self, code: int, text: str):
        data = (text + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # sonde de vie
        self._reply(200, "ok")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        event = self.headers.get("X-Gitlab-Event", "?")
        msg_id = self.headers.get("webhook-id") or self.headers.get("Idempotency-Key") or ""
        rec = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "from": self.client_address[0],
               "event": event, "id": msg_id, "uuid": self.headers.get("X-Gitlab-Event-UUID"),
               "instance": self.headers.get("X-Gitlab-Instance"), "bytes": len(body)}
        token = self.headers.get("X-Gitlab-Token", "")
        if SECRET and not hmac.compare_digest(token.encode(), SECRET.encode()):
            rec["verdict"] = "REFUSÉ: jeton absent ou invalide"
            code = 401
        elif reason := verify_signature(self.headers, body):
            rec["verdict"] = f"REFUSÉ: {reason}"
            code = 401
        else:
            with lock:
                dup = msg_id and msg_id in seen_ids
                seen_ids.add(msg_id)
            try:
                rec.update(summary(event, json.loads(body or b"{}")))
            except json.JSONDecodeError:
                rec["verdict"] = "REFUSÉ: JSON invalide"
                code = 400
            else:
                rec["verdict"] = "doublon ignoré" if dup else "accepté"
                code = 200
        with lock, open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print(json.dumps(rec, ensure_ascii=False), flush=True)
        self._reply(code, rec["verdict"])

    def log_message(self, *args):  # pas de journal d'accès HTTP par défaut (on a le nôtre)
        pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8095)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--log", default=os.path.expanduser("~/m09-webhooks/events.jsonl"))
    a = ap.parse_args()
    LOG = a.log
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    if not SECRET:
        print("ATTENTION : WEBHOOK_SECRET vide, aucun contrôle du jeton", file=sys.stderr)
    print(f"Écoute sur {a.bind}:{a.port}, journal {LOG}, signature {'vérifiée' if SIGNING else 'non vérifiée'}",
          flush=True)
    ThreadingHTTPServer((a.bind, a.port), Handler).serve_forever()
