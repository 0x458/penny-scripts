#!/usr/bin/env python3
# Stub for https://huggingface.co/api/models/<org>/<name>/revision/<sha>?blobs=true, sizes from $FAKE_HF_DATA/<name>/.
import http.server, json, os, re, sys
DATA = os.environ["FAKE_HF_DATA"]; HUGE = {"Huge-NVFP4": 10**16}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *x): pass
    def do_GET(self):
        m = re.match(r"/api/models/([^/]+)/([^/]+)/revision/([0-9a-f]{40})", self.path)
        if not m: self.send_response(404); self.end_headers(); return
        name, rev = m.group(2), m.group(3); d = os.path.join(DATA, name)
        sib = [{"rfilename": f, "size": os.path.getsize(os.path.join(d, f))} for f in os.listdir(d)] if os.path.isdir(d) else []
        if name in HUGE: sib = [{"rfilename": "x", "size": HUGE[name]}]
        b = json.dumps({"id": f"{m.group(1)}/{name}", "sha": rev, "siblings": sib}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(b)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
