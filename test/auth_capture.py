#!/usr/bin/env python3
# Records the Authorization header git sends (to prove GH_TOKEN goes out as an http header), then answers 403.
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *x): pass
    def do_GET(self):
        open(sys.argv[2], "a").write((self.headers.get("Authorization") or "-") + "\n"); self.send_response(403); self.end_headers()
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
