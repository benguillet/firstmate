# lab fault proxy: forwards to the real lab T3 server; after a thread.turn.start
# dispatch is accepted upstream, answers GET /api/orchestration/threads/* with 503
# for POISON_SECS so the landing re-read fails. Logs every request.
import http.server, json, sys, time, urllib.request, urllib.error
UP = "http://127.0.0.1:3791"; PORT = int(sys.argv[1]); LOG = sys.argv[2]; POISON_SECS = 20
state = {"until": 0.0}
def log(s):
    with open(LOG, "a") as f: f.write(time.strftime("%H:%M:%S ") + s + "\n")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _go(self):
        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n) if n else None
        mode = open("/tmp/fm-t3-lab-1s10/proxy.mode").read().strip() if __import__("os").path.exists("/tmp/fm-t3-lab-1s10/proxy.mode") else "pending"
        if mode == "fail-turn-start" and self.command == "POST" and body and b'"thread.turn.start"' in body:
            log(f"{self.command} {self.path} thread.turn.start -> 500 (injected, not forwarded)")
            self.send_response(500); self.send_header("Content-Length", "0"); self.end_headers(); return
        if self.command == "GET" and self.path.startswith("/api/orchestration/threads/") and time.time() < state["until"]:
            log(f"{self.command} {self.path} -> 503 (injected)")
            self.send_response(503); self.send_header("Content-Length", "0"); self.end_headers(); return
        req = urllib.request.Request(UP + self.path, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in ("host", "content-length", "connection"): req.add_header(k, v)
        try:
            r = urllib.request.urlopen(req, timeout=30); code, data, hdrs = r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            code, data, hdrs = e.code, e.read(), e.headers
        kind = ""
        if self.command == "POST" and self.path == "/api/orchestration/dispatch" and body:
            try: kind = json.loads(body).get("type", "")
            except Exception: pass
            if kind == "thread.turn.start" and 200 <= code < 300 and mode == "pending":
                state["until"] = time.time() + POISON_SECS
            if kind == "thread.create" and 200 <= code < 300 and mode == "fail-reads-after-create":
                state["until"] = time.time() + 120
        log(f"{self.command} {self.path} {kind} -> {code}")
        self.send_response(code)
        ct = hdrs.get("Content-Type")
        if ct: self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    do_GET = do_POST = _go
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
