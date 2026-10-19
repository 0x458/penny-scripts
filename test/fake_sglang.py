#!/usr/bin/env python3
# Stub for /opt/pennyroyal/.venv/bin/sglang: records argv, prints a SGLang-like server_args line (with the api key,
# like the real one does), serves /health and /v1/models on --port, exits on SIGTERM.
import http.server, json, os, signal, sys
a = sys.argv[1:]; g = lambda k: a[a.index(k) + 1] if k in a else None
open(os.environ["FAKE_ARGV_OUT"], "a").write(json.dumps(a) + "\n")
print(f"server_args=ServerArgs(model_path='{g('--model-path')}', api_key='{g('--api-key')}', hicache_size={g('--hicache-size')}, "
      f"speculative_token_map={g('--speculative-token-map')!r})", flush=True)
print(f"[fake-sglang] api key again on stderr: {g('--api-key')}", file=sys.stderr, flush=True)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *x): pass
    def do_GET(self):
        b = json.dumps({"model_path": g("--model-path")}).encode(); self.send_response(200); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(("127.0.0.1", int(g("--port"))), H).serve_forever()
