"""Local stand-in for Kimi Code's usage API and for GitHub release downloads, used by
run-tests.ps1. Writes the port it listens on to PORTFILE.

    python -I mock_server.py PORTFILE FILEDIR

GET /coding/v1/usages  -> a usage report (needs "Authorization: Bearer test-token");
                          /weekly/coding/v1/usages: the week only;
                          /now/coding/v1/usages: the 5-hour window resets this second
POST /coding/v1/client_configs {"name": ...}
                       -> a client config: the prompt-cache rules (no token needed)
GET /download/<name>   -> FILEDIR/<name>
"""
import datetime
import http.server
import json
import os
import sys

TOKEN = "test-token"
PORTFILE, FILES = sys.argv[1], sys.argv[2]


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def usages(variant):
    # the shape statusline.sh reads first: a 5-hour window in limits[], the week in usage
    now = datetime.datetime.now(datetime.timezone.utc)
    five = datetime.timedelta(0) if variant == "now" else datetime.timedelta(hours=2)
    report = {
        "usage": {"limit": "100", "used": "52", "remaining": "48",
                  "resetTime": iso(now + datetime.timedelta(days=3))},
        "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
                    "detail": {"limit": "100", "used": "5", "remaining": "95",
                               "resetTime": iso(now + five)}}],
    }
    if variant == "weekly":
        del report["limits"]
    return report


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        for variant in ("", "weekly", "now"):
            if self.path == ("/" + variant if variant else "") + "/coding/v1/usages":
                if self.headers.get("Authorization") != "Bearer " + TOKEN:
                    return self.reply(401, b'{"error":"unauthorized"}')
                return self.reply(200, json.dumps(usages(variant)).encode())
        if self.path.startswith("/download/"):
            path = os.path.join(FILES, os.path.basename(self.path))
            if os.path.isfile(path):
                with open(path, "rb") as f:
                    return self.reply(200, f.read(), "application/octet-stream")
        self.reply(404, b"not found", "text/plain")

    def do_POST(self):
        if self.path == "/coding/v1/client_configs":
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            try:
                name = json.loads(body).get("name")
            except (ValueError, AttributeError):
                return self.reply(400, b'{"error":"bad request"}')
            config = {}
            if name == "estimated_cache_duration":
                config = {"version": 1, "config": {
                    "k3": {"min_tokens_to_hint": 200000, "cache_duration": 1800},
                    "kimi-for-coding": {"min_tokens_to_hint": 200000, "cache_duration": 3600}}}
            return self.reply(200, json.dumps({"name": name, "config": config}).encode())
        self.reply(404, b"not found", "text/plain")

    def reply(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORTFILE + ".tmp", "w") as f:
    f.write(str(server.server_port))
os.replace(PORTFILE + ".tmp", PORTFILE)
server.serve_forever()
