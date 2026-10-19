# Penny control server (v5, based on v4-orca): auth'd status/log/mode-switch + whitelisted model download/switch.
# No arbitrary exec: subprocess only with fixed argument lists (never shell=True); the API key is masked in
# everything this process prints or serves (SGLang prints server_args incl. api_key at startup).
import hashlib, hmac, http.server, json, os, re, shutil, signal, subprocess, sys, threading, time, urllib.parse, urllib.request
KEY = os.environ["PENNY_API_KEY"]; KEYB = KEY.encode(); MASK = b"<API_KEY>"
C = os.environ.get("PENNY_CACHE", "/cache"); LOG = C + "/logs"
START = os.environ.get("PENNY_START_DIR", C)                       # boot.sh writes start-frspec.sh / start-plain.sh here
ROOT = os.path.realpath(os.environ.get("PENNY_MODELS_ROOT", C + "/models"))
PORT = int(os.environ.get("PENNY_CTL_PORT", "8002"))
HF = os.environ.get("HF_ENDPOINT", "https://huggingface.co").rstrip("/")
HF_BIN = os.environ.get("PENNY_HF_BIN", "/opt/pennyroyal/.venv/bin/hf")
RETRIES = max(1, int(os.environ.get("PENNY_DL_RETRIES", "4")))           # network errors and incomplete downloads
RETRY_DELAY = float(os.environ.get("PENNY_DL_RETRY_DELAY", "30"))        # seconds, x attempt number
MAX_RESTARTS = int(os.environ.get("PENNY_MAX_RESTARTS", "3"))            # automatic restarts after a crash, per manual launch
RESTART_DELAY = float(os.environ.get("PENNY_RESTART_DELAY", "20"))
RESERVE_GB = float(os.environ.get("PENNY_DISK_RESERVE_GB", "40"))  # JIT caches + logs
ALLOW_FILE = os.environ.get("PENNY_ALLOW_FILE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "models.allow"))
DEFAULT = "jpezzulli/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4@f24d2b68ff2814f24455ae86717be276619b5664"
FRSPEC_TOK_SHA = "0997f410c57a1f4e53b09e4be8f4a172d90edd9564368fb0847030937229b9f3"   # what start-flash-next-frspec.sh demands
SPEC_RE = re.compile(r"([A-Za-z0-9][A-Za-z0-9_-]{0,38})/([A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)*)@([0-9a-f]{40})")
os.makedirs(LOG, exist_ok=True); os.makedirs(ROOT, exist_ok=True)

def rd(p):
    try: return open(p).read().strip()
    except OSError: return ""
def allowed():
    out = set()
    for line in rd(ALLOW_FILE).splitlines():
        line = line.split("#", 1)[0].strip()
        if line and SPEC_RE.fullmatch(line) and len(line) < 200: out.add(line)
    return out or {DEFAULT}
def valid(spec):
    """None if spec is a syntactically strict, whitelisted org/repo@sha; else an error string."""
    if not isinstance(spec, str) or len(spec) > 200 or not SPEC_RE.fullmatch(spec): return "bad model (org/repo@40-hex)"
    if spec not in allowed(): return "model not in whitelist"
    return None
def mdir(spec):
    p = os.path.realpath(os.path.join(ROOT, SPEC_RE.fullmatch(spec).group(2)))
    if os.path.dirname(p) != ROOT: raise ValueError("path escapes models root")
    return p
def complete(spec):
    try: return json.load(open(mdir(spec) + "/.complete")).get("spec") == spec
    except (OSError, ValueError): return False
def tok_ok(spec):
    try:
        with open(mdir(spec) + "/tokenizer.json", "rb") as f: return hashlib.sha256(f.read()).hexdigest() == FRSPEC_TOK_SHA
    except OSError: return False

a0 = rd(C + "/active"); a0 = a0 if not valid(a0) else os.environ.get("PENNY_MODEL", DEFAULT)
if valid(a0): print(f"PENNY: PENNY_MODEL {a0!r} rejected ({valid(a0)}), using default", flush=True); a0 = DEFAULT
m0 = rd(C + "/mode") or os.environ.get("PENNY_MODE", "plain")      # Chinese is ~46% faster without FR-Spec
st = {"mode": m0 if m0 in ("frspec", "plain") else "plain", "active": a0, "proc": None, "started": None, "phase": "boot",
      "job": None, "err": None, "restarts": 0}
lock = threading.Lock()

def pump(p, path):
    with open(path, "ab") as f:
        for line in iter(p.stdout.readline, b""):
            line = line.replace(KEYB, MASK); f.write(line); f.flush(); sys.stdout.buffer.write(line); sys.stdout.flush()
def launch(manual=True):
    """Caller holds lock. manual=True (boot/switch/mode) resets the crash-restart budget."""
    if manual: st["restarts"] = 0
    m, a = st["mode"], st["active"]
    if m == "frspec" and not tok_ok(a): m = st["mode"] = "plain"; st["err"] = "tokenizer fails FR-Spec check; using plain"
    path = f"{LOG}/server-{m}.log"
    env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "TS_AUTHKEY", "HF_TOKEN")}
    env["PENNY_MODEL_DIR"] = mdir(a)
    with open(path, "ab") as f: f.write(f"\n==== launch {m} {a} {time.ctime()} ====\n".encode())
    p = subprocess.Popen(["bash", f"{START}/start-{m}.sh"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True, env=env)
    st.update(proc=p, started=time.time(), phase="serving:" + m)
    threading.Thread(target=pump, args=(p, path), daemon=True).start()
    threading.Thread(target=watch, args=(p,), daemon=True).start()
    print(f"PENNY: launched {m} {a} pid {p.pid}", flush=True)
def watch(p):
    """Restart SGLang a limited number of times if it exits on its own. stop() clears st["proc"] first, so an
    intentional stop (switch/mode) is never counted as a crash."""
    rc = p.wait()
    if st["proc"] is not p: return
    if st["restarts"] >= MAX_RESTARTS:
        st.update(phase=f"crashed rc={rc}", err=f"SGLang exited rc={rc}; gave up after {st['restarts']} restarts")
        print(f"PENNY: ERROR SGLang exited rc={rc}, restart budget ({MAX_RESTARTS}) used up", flush=True); return
    st["phase"] = f"restarting rc={rc}"
    print(f"PENNY: SGLang exited rc={rc}; restart {st['restarts']+1}/{MAX_RESTARTS} in {RESTART_DELAY:g}s", flush=True)
    time.sleep(RESTART_DELAY)
    with lock:
        if st["proc"] is not p: return          # a switch/mode happened meanwhile
        st["restarts"] += 1; launch(manual=False)
def stop():
    p = st["proc"]; st["proc"] = None            # clear first: watch() then knows this exit is intentional
    if p and p.poll() is None:
        os.killpg(p.pid, signal.SIGTERM)
        for _ in range(90):
            if p.poll() is not None: break
            time.sleep(1)
        else: os.killpg(p.pid, signal.SIGKILL); p.wait()
def du(p):
    t = 0
    for r, _, fs in os.walk(p):
        for f in fs:
            try: t += os.path.getsize(os.path.join(r, f))
            except OSError: pass
    return t
def tail(path, n):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2); s = f.tell(); f.seek(max(0, s - 200000)); return b"\n".join(f.read().splitlines()[-n:]).replace(KEYB, MASK).decode("utf-8", "replace")
    except OSError as e: return str(e)

def download(spec):
    """Pinned-revision download into ROOT/<repo>, disk check first, .complete marker last. Returns error or None."""
    if complete(spec): return None
    repo, rev = spec.rsplit("@", 1); d = mdir(spec)
    try:
        req = urllib.request.Request(f"{HF}/api/models/{repo}/revision/{rev}?blobs=true")
        if os.environ.get("HF_TOKEN"): req.add_header("Authorization", "Bearer " + os.environ["HF_TOKEN"])
        meta = json.load(urllib.request.urlopen(req, timeout=30))
        if meta.get("sha") != rev: return f"HF revision mismatch {meta.get('sha')}"
        size = sum(int(s.get("size") or 0) for s in meta.get("siblings", []))
    except Exception as e: return f"HF metadata: {e}"
    need = max(0, size - (du(d) if os.path.isdir(d) else 0)) + RESERVE_GB * 1e9; free = shutil.disk_usage(ROOT).free
    if need > free: return f"disk: need {need/1e9:.1f} GB (incl. {RESERVE_GB:g} GB reserve), free {free/1e9:.1f} GB"
    os.makedirs(d, exist_ok=True)
    if os.access(HF_BIN, os.X_OK): cmd = [HF_BIN, "download", repo, "--revision", rev, "--local-dir", d, "--max-workers", "16"]
    else: cmd = [sys.executable, "-c", "import sys;from huggingface_hub import snapshot_download as s;s(sys.argv[1],revision=sys.argv[2],local_dir=sys.argv[3],max_workers=16)", repo, rev, d]
    env = {k: v for k, v in os.environ.items() if k not in ("PENNY_API_KEY", "GH_TOKEN", "TS_AUTHKEY")}; env["HF_HUB_ENABLE_HF_TRANSFER"] = "0"
    st["phase"] = f"downloading {size/1e9:.1f} GB"; print(f"PENNY: downloading {spec} ({size/1e9:.1f} GB) {time.ctime()}", flush=True)
    with open(f"{LOG}/download.log", "ab") as f: rc = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=env).returncode
    got = du(d)
    if rc != 0: return f"downloader rc={rc}"
    if got < size * 0.99 or not os.path.isfile(d + "/config.json"): return f"incomplete: {got}/{size} bytes"
    with open(d + "/.complete", "w") as f: json.dump({"spec": spec, "bytes": got, "t": time.time()}, f)
    print(f"PENNY: model download done {spec} tokenizer_frspec_ok={tok_ok(spec)} {time.ctime()}", flush=True)
    return None
def job(spec, mode):
    """Download if needed, then (re)start the server on spec. Server keeps running on the old model while downloading."""
    try:
        for i in range(RETRIES):
            err = download(spec)
            if not err or not err.startswith(("HF metadata", "downloader", "incomplete")) or i == RETRIES - 1: break
            print(f"PENNY: download attempt {i+1} failed ({err}); retry in {RETRY_DELAY*(i+1):g}s", flush=True); time.sleep(RETRY_DELAY * (i + 1))
        if err: st.update(err=err, phase="error" if st["proc"] is None else st["phase"]); print("PENNY: ERROR " + err, flush=True); return
        with lock:
            stop(); st.update(active=spec, mode=mode, err=None); open(C + "/active", "w").write(spec); open(C + "/mode", "w").write(mode); launch()
    finally: st["job"] = None
def start_job(spec, mode):
    with lock:
        if st["job"]: return False
        st["job"] = spec
    threading.Thread(target=job, args=(spec, mode), daemon=True).start(); return True

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def out(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode().replace(KEYB, MASK); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def auth(self):
        if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), b"Bearer " + KEYB): self.out(401, {"err": "auth"}); return False
        return True
    def do_GET(self):
        if not self.auth(): return
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        if u.path == "/status":
            p = st["proc"]; d = shutil.disk_usage(ROOT)
            self.out(200, {"phase": st["phase"], "mode": st["mode"], "active": st["active"], "job": st["job"], "err": st["err"],
                "pid": p and p.pid, "rc": p and p.poll(), "restarts": st["restarts"], "up_s": st["started"] and round(time.time() - st["started"]),
                "model_bytes": du(mdir(st["active"])), "disk_used_gb": round(d.used/1e9, 1), "disk_free_gb": round(d.free/1e9, 1),
                "mem": open("/proc/meminfo").read().splitlines()[:3]})
        elif u.path == "/models":
            d = shutil.disk_usage(ROOT)
            self.out(200, {"active": st["active"], "disk_free_gb": round(d.free/1e9, 1), "models": [
                {"spec": s, "complete": complete(s), "gb": round(du(mdir(s))/1e9, 2), "frspec_ok": tok_ok(s)} for s in sorted(allowed())]})
        elif u.path == "/log":
            f = q.get("f", ["server"])[0]
            try: n = max(1, min(2000, int(q.get("n", ["80"])[0])))
            except ValueError: return self.out(400, {"err": "n"})
            path = {"server": f"{LOG}/server-{st['mode']}.log", "download": f"{LOG}/download.log", "boot": f"{LOG}/boot.log",
                    "bootstrap": f"{LOG}/bootstrap.log", "server-frspec": f"{LOG}/server-frspec.log", "server-plain": f"{LOG}/server-plain.log"}.get(f)
            self.out(200 if path else 400, {"f": f, "text": tail(path, n) if path else "bad f"})
        elif u.path == "/smi":
            try: r = subprocess.run(["nvidia-smi"], capture_output=True, text=True, timeout=20); t = r.stdout + r.stderr
            except (OSError, subprocess.TimeoutExpired) as e: t = str(e)
            self.out(200, {"text": t})
        else: self.out(404, {})
    def do_POST(self):
        if not self.auth(): return
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        if u.path == "/mode":
            m = q.get("m", [""])[0]
            if m not in ("frspec", "plain"): return self.out(400, {"err": "m"})
            if m == "frspec" and not tok_ok(st["active"]): return self.out(409, {"err": "tokenizer fails FR-Spec check"})
            with lock:
                stop(); st["mode"] = m; open(C+"/mode", "w").write(m)
                if complete(st["active"]): launch()
            self.out(200, {"mode": m, "pid": st["proc"] and st["proc"].pid})
        elif u.path == "/switch":
            spec = q.get("model", [""])[0]; m = q.get("m", [st["mode"]])[0]
            err = valid(spec) or (None if m in ("frspec", "plain") else "bad m")
            if err: return self.out(400, {"err": err})
            if not start_job(spec, m): return self.out(409, {"err": "busy", "job": st["job"]})
            self.out(202, {"switching_to": spec, "mode": m, "downloaded": complete(spec)})
        else: self.out(404, {})

start_job(st["active"], st["mode"])
print(f"PENNY: ctl listening {PORT} active={st['active']} mode={st['mode']}", flush=True)
http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
