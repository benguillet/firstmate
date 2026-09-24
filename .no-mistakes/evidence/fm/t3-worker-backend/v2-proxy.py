import http.client, http.server, os, socketserver, sys
UP_HOST, UP_PORT = "127.0.0.1", int(sys.argv[1])
LISTEN = int(sys.argv[2])
MODE_FILE = sys.argv[3]
LOG = sys.argv[4]
def mode():
    try:
        return open(MODE_FILE).read().strip() or "pass"
    except OSError:
        return "pass"
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _go(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        m = mode()
        path = self.path.split("?")[0]
        if m == "v2" and self.command == "POST" and path == "/api/orchestration/dispatch":
            with open(LOG, "a") as f: f.write(f"{m} {self.command} {self.path} -> 404 (route removed)\n")
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length", "connection")}
        if m == "badauth" and "Authorization" in hdrs:
            hdrs["Authorization"] = "Bearer not-a-token-this-server-issued"
        c = http.client.HTTPConnection(UP_HOST, UP_PORT, timeout=30)
        c.request(self.command, self.path, body=body, headers=hdrs)
        r = c.getresponse(); data = r.read()
        with open(LOG, "a") as f: f.write(f"{m} {self.command} {self.path} -> {r.status}\n")
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    do_GET = do_POST = _go
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
S(("127.0.0.1", LISTEN), H).serve_forever()
