#!/usr/bin/env python3
"""
Module 06 - Récepteur de webhooks minimal pour tester les notifications d'alerte
(Alertmanager et Grafana Alerting envoient un POST JSON).

Usage : ./recepteur_webhook.py [port] [fichier]      (défaut : 9097, /tmp/m06-webhook.log)
Chaque notification reçue est ajoutée au fichier (une ligne JSON résumée par alerte).
Arrêt : Ctrl+C (ou pkill -f recepteur_webhook.py).
"""
import json
import sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9097
LOG = sys.argv[2] if len(sys.argv) > 2 else "/tmp/m06-webhook.log"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            data = json.loads(body)
        except ValueError:
            data = {"brut": body.decode(errors="replace")}
        # Format commun Alertmanager / Grafana : {"status": ..., "alerts": [{labels, annotations, ...}]}
        with open(LOG, "a", encoding="utf-8") as fh:
            for a in data.get("alerts", [data]):
                fh.write(json.dumps({
                    "recu": datetime.now().isoformat(timespec="seconds"),
                    "source": self.headers.get("User-Agent", "?").split("/")[0],
                    "chemin": self.path,
                    "status": a.get("status", data.get("status")),
                    "alertname": a.get("labels", {}).get("alertname"),
                    "summary": a.get("annotations", {}).get("summary"),
                }, ensure_ascii=False) + "\n")
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):  # pas de journal HTTP sur la sortie standard
        pass


if __name__ == "__main__":
    print(f"écoute sur 127.0.0.1:{PORT}, journal {LOG}", flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
