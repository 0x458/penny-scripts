# Penny control server (v5, based on v4-orca): auth'd status/log/mode-switch + whitelisted model download/switch.
# POST /config writes /cache/config.json (mode, HiCache, context, whitelisted model) and restarts SGLang.
# Mode 27b serves the pinned Qwen3.8-27B AWQ with its DFlash2 draft. It does not serve Flash-Next weights.
# POST /upgrade records a release tag in /cache/penny-ref; the next vastai reboot fetches it. No arbitrary exec:
# subprocess only with fixed argument lists (never shell=True); the API key is masked in everything this process
# prints or serves (SGLang prints server_args incl. api_key at startup).
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
CFG_PATH = C + "/config.json"; REF_PATH = C + "/penny-ref"
CONTEXTS = {65536, 131072, 262144, 524288}
CONTEXTS_27B = {32768, 65536, 98304, 126784}
CONTEXT_27B_DEFAULT = 126784
HICACHE_DEFAULT = 48  # ceiling, and the size used, when PENNY_RAM_GB is unset
TAG_RE = re.compile(r"v[0-9]+\.[0-9]+(?:\.[0-9]+)?")
REPO_URL = os.environ.get("PENNY_REPO_URL", "")
DEFAULT = "jpezzulli/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4@f24d2b68ff2814f24455ae86717be276619b5664"
# AWQ W4A16 of orcarouter/Qwen3.8-27B-Uncensored. Chosen, not TBD: it is a real uncensored 4-bit
# checkpoint and it fits a 32 GB card with the DFlash2 draft. PENNY_27B_MODEL may name another
# whitelisted spec. The draft is not a /switch target.
MODEL_27B_PIN = "Ar4ikov/Qwen3.8-27B-Uncensored-AWQ-W4A16-ASYM@d07667d03a5dbfebd02a4eaa55348b97f35d1935"
DRAFT_27B_PIN = "incoai/Qwen3.8-27B-DFlash2@015e795645c74b1a0eeef3b570031fb62e769bc5"
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

def load_cfg():
    try:
        d = json.load(open(CFG_PATH))
    except (OSError, ValueError): return {}
    return d if isinstance(d, dict) else {}
def hicache_max():
    # Leave 100 GB for the system and the model (RAM PLE ~51 GB + process/pinned buffers ~40 GB).
    # max = PENNY_RAM_GB - 100 when PENNY_RAM_GB is a positive integer; otherwise 48.
    raw = os.environ.get("PENNY_RAM_GB")
    if not raw: return HICACHE_DEFAULT
    try: ram = int(raw)
    except ValueError: return HICACHE_DEFAULT
    return ram - 100 if ram > 0 else HICACHE_DEFAULT
def model_27b():
    """Whitelisted 27B spec. PENNY_27B_MODEL wins only when it is on the allow list."""
    cand = os.environ.get("PENNY_27B_MODEL", "")
    if cand and not valid(cand): return cand
    return MODEL_27B_PIN
def draft_27b():
    """DFlash2 draft downloaded beside the 27B target. Not a /switch model."""
    cand = os.environ.get("PENNY_27B_DRAFT", "")
    if SPEC_RE.fullmatch(cand) and len(cand) < 200: return cand
    return DRAFT_27B_PIN
def mode_fits(spec, mode):
    """27b serves only the pinned 27B spec. plain and frspec never serve it."""
    if mode == "27b": return spec == model_27b()
    return spec != model_27b()
def hicache_cap_27b():
    """0 when RAM is missing or under 108 GB (no pinned host pool). Else min(96, RAM-100)."""
    raw = os.environ.get("PENNY_RAM_GB")
    if not raw: return 0
    try: ram = int(raw)
    except ValueError: return 0
    if ram < 108: return 0
    return min(96, ram - 100)
def hicache_ok(n, mode="flash"):
    """None if n is an allowed HiCache size; else an error string. mode 27b uses the 5090 rules."""
    if mode == "27b": return hicache_ok_27b(n)
    if isinstance(n, bool) or not isinstance(n, int): return "hicache_gb"
    cap = hicache_max()
    if n < 8 or n > cap: return f"hicache_gb must be 8..{cap}"
    return None
def hicache_ok_27b(n):
    if isinstance(n, bool) or not isinstance(n, int): return "hicache_gb"
    cap = hicache_cap_27b()
    if cap == 0:
        if n != 0: return "hicache_gb must be 0"
        return None
    if n == 0: return None
    if n < 8 or n > cap: return f"hicache_gb must be 0 or 8..{cap}"
    return None
def context_ok(n, mode="flash"):
    if mode == "27b":
        if isinstance(n, bool) or n not in CONTEXTS_27B: return "context must be 32768|65536|98304|126784"
        return None
    if isinstance(n, bool) or n not in CONTEXTS: return "context must be 65536|131072|262144|524288"
    return None
def atomic_write(path, text):
    """Write path via temp file + rename so a crash cannot leave a half-written mode or active file."""
    if not text.endswith("\n"): text += "\n"
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
def save_cfg():
    body = {"mode": st["mode"], "model": st["active"], "hicache_gb": st["hicache_gb"], "context_length": st["context"]}
    tmp = CFG_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(body, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, CFG_PATH)
def apply_runtime():
    if st["mode"] == "27b":
        os.environ["PENNY_27B_HICACHE_GB"] = str(st["hicache_gb"])
        os.environ["PENNY_27B_CONTEXT_LENGTH"] = str(st["context"])
    else:
        os.environ["PENNY_HICACHE_GB"] = str(st["hicache_gb"])
        os.environ["PENNY_CONTEXT_LENGTH"] = str(st["context"])
def pick_model(cfg, mode):
    fallback = model_27b() if mode == "27b" else DEFAULT
    cm = cfg.get("model")
    if isinstance(cm, str) and valid(cm): print(f"PENNY: config model {cm!r} rejected ({valid(cm)}), using fallback", flush=True)
    for cand in (cm, rd(C + "/active"), os.environ.get("PENNY_MODEL", ""), fallback):
        if isinstance(cand, str) and not valid(cand) and mode_fits(cand, mode): return cand
    return fallback
def pick_mode(cfg):
    for cand in (cfg.get("mode"), rd(C + "/mode"), os.environ.get("PENNY_MODE", "")):  # default plain: Chinese is faster without FR-Spec
        if cand in ("frspec", "plain", "27b"): return cand
    return "plain"
def pick_hicache(cfg, mode="flash"):
    if mode == "27b":
        h = cfg.get("hicache_gb")
        if isinstance(h, int) and not isinstance(h, bool) and not hicache_ok(h, "27b"): return h
        raw = os.environ.get("PENNY_27B_HICACHE_GB")
        if raw is not None:
            try: h = int(raw)
            except ValueError: h = None
            if isinstance(h, int) and not isinstance(h, bool) and not hicache_ok(h, "27b"): return h
        return hicache_cap_27b()
    h = cfg.get("hicache_gb")
    if isinstance(h, int) and not isinstance(h, bool) and not hicache_ok(h): return h
    try: h = int(os.environ["PENNY_HICACHE_GB"])
    except (KeyError, ValueError): h = HICACHE_DEFAULT
    if hicache_ok(h):
        cap = hicache_max()
        h = cap if cap >= 8 else 8
    return h
def pick_context(cfg, mode="flash"):
    if mode == "27b":
        c = cfg.get("context_length")
        if isinstance(c, int) and not isinstance(c, bool) and not context_ok(c, "27b"): return c
        raw = os.environ.get("PENNY_27B_CONTEXT_LENGTH")
        if raw is not None:
            try: c = int(raw)
            except ValueError: c = None
            if isinstance(c, int) and not isinstance(c, bool) and not context_ok(c, "27b"): return c
        return CONTEXT_27B_DEFAULT
    c = cfg.get("context_length")
    if isinstance(c, int) and not isinstance(c, bool) and not context_ok(c): return c
    return 524288
def clamp_runtime(mode):
    """Make stored HiCache and context legal for mode. A no-op when they already are."""
    if context_ok(st["context"], mode):
        st["context"] = CONTEXT_27B_DEFAULT if mode == "27b" else 524288
    if hicache_ok(st["hicache_gb"], mode):
        if mode == "27b": st["hicache_gb"] = hicache_cap_27b()
        else:
            cap = hicache_max()
            st["hicache_gb"] = cap if cap >= 8 else 8

cfg0 = load_cfg()
mode0 = pick_mode(cfg0)
st = {"mode": mode0, "active": pick_model(cfg0, mode0), "hicache_gb": pick_hicache(cfg0, mode0), "context": pick_context(cfg0, mode0),
      "proc": None, "started": None, "phase": "boot", "job": None, "err": None, "restarts": 0}
lock = threading.Lock()
apply_runtime(); save_cfg()

def pump(p, path):
    with open(path, "ab") as f:
        for line in iter(p.stdout.readline, b""):
            line = line.replace(KEYB, MASK); f.write(line); f.flush(); sys.stdout.buffer.write(line); sys.stdout.flush()
def launch(manual=True):
    """Caller holds lock. manual=True (boot/switch/mode) resets the crash-restart budget."""
    if manual: st["restarts"] = 0
    apply_runtime()
    m, a = st["mode"], st["active"]
    if m == "frspec" and not tok_ok(a):
        m = st["mode"] = "plain"; st["err"] = "tokenizer fails FR-Spec check; using plain"; save_cfg()
    path = f"{LOG}/server-{m}.log"
    env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "TS_AUTHKEY", "HF_TOKEN")}
    env["PENNY_MODEL_DIR"] = mdir(a)
    if m == "27b": env["PENNY_DRAFT_MODEL_DIR"] = mdir(draft_27b())
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
        if not err and mode == "27b":
            draft = draft_27b()
            for i in range(RETRIES):
                err = download(draft)
                if not err or not err.startswith(("HF metadata", "downloader", "incomplete")) or i == RETRIES - 1: break
                print(f"PENNY: download attempt {i+1} failed ({err}); retry in {RETRY_DELAY*(i+1):g}s", flush=True); time.sleep(RETRY_DELAY * (i + 1))
        if err: st.update(err=err, phase="error" if st["proc"] is None else st["phase"]); print("PENNY: ERROR " + err, flush=True); return
        with lock:
            clamp_runtime(mode)
            stop(); st.update(active=spec, mode=mode, err=None); atomic_write(C + "/active", spec); atomic_write(C + "/mode", mode); save_cfg(); launch()
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
                "hicache_gb": st["hicache_gb"], "context_length": st["context"], "ref": rd(REF_PATH) or None,
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
                    "bootstrap": f"{LOG}/bootstrap.log", "server-frspec": f"{LOG}/server-frspec.log",
                    "server-plain": f"{LOG}/server-plain.log", "server-27b": f"{LOG}/server-27b.log"}.get(f)
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
            if m not in ("frspec", "plain", "27b"): return self.out(400, {"err": "m"})
            pin = model_27b()
            if m == "27b" and st["active"] != pin: return self.out(409, {"err": "27b requires the 27B model"})
            if m != "27b" and st["active"] == pin: return self.out(409, {"err": "27B model requires mode 27b"})
            if m == "frspec" and not tok_ok(st["active"]): return self.out(409, {"err": "tokenizer fails FR-Spec check"})
            with lock:
                stop(); st["mode"] = m; atomic_write(C + "/mode", m); save_cfg(); apply_runtime()
                ready = complete(st["active"]) and (m != "27b" or complete(draft_27b()))
                if ready: launch()
            self.out(200, {"mode": m, "pid": st["proc"] and st["proc"].pid})
        elif u.path == "/switch":
            spec = q.get("model", [""])[0]; m = q.get("m", [None])[0]
            if m is None: m = "27b" if spec == model_27b() else st["mode"]
            err = valid(spec) or (None if m in ("frspec", "plain", "27b") else "bad m")
            if not err and not mode_fits(spec, m): err = "mode does not match model"
            if err: return self.out(400, {"err": err})
            if not start_job(spec, m): return self.out(409, {"err": "busy", "job": st["job"]})
            self.out(202, {"switching_to": spec, "mode": m, "downloaded": complete(spec)})
        elif u.path == "/config":
            m = q.get("m", [None])[0]; hs = q.get("hicache_gb", [None])[0]; cs = q.get("context", [None])[0]; model = q.get("model", [None])[0]
            if m is None and hs is None and cs is None and model is None: return self.out(400, {"err": "set m, hicache_gb, context, or model"})
            if m is not None and m not in ("frspec", "plain", "27b"): return self.out(400, {"err": "m"})
            pin = model_27b()
            if model is not None:
                err = valid(model)
                if err: return self.out(400, {"err": err})
            if m == "frspec" and model is None and not tok_ok(st["active"]): return self.out(409, {"err": "tokenizer fails FR-Spec check"})
            if model is not None and m is None and model == pin: mode = "27b"
            else: mode = m or st["mode"]
            if model is not None and not mode_fits(model, mode): return self.out(400, {"err": "mode does not match model"})
            if model is None and m == "27b" and st["active"] != pin: return self.out(409, {"err": "27b requires the 27B model"})
            if model is None and m in ("plain", "frspec") and st["active"] == pin: return self.out(409, {"err": "27B model requires mode 27b"})
            h_new, c_new = st["hicache_gb"], st["context"]
            if hs is not None:
                if not re.fullmatch(r"0|[1-9][0-9]{0,2}" if mode == "27b" else r"[1-9][0-9]{0,2}", hs): return self.out(400, {"err": "hicache_gb"})
                h_new = int(hs); err = hicache_ok(h_new, mode)
                if err: return self.out(400, {"err": err})
            if cs is not None:
                if not re.fullmatch(r"[1-9][0-9]{0,6}", cs): return self.out(400, {"err": "context"})
                c_new = int(cs); err = context_ok(c_new, mode)
                if err: return self.out(400, {"err": err})
            entering = mode == "27b" and st["mode"] != "27b"
            leaving = mode != "27b" and st["mode"] == "27b"
            if entering or leaving:
                if cs is None and context_ok(c_new, mode): c_new = CONTEXT_27B_DEFAULT if mode == "27b" else 524288
                if hs is None and hicache_ok(h_new, mode):
                    if mode == "27b": h_new = hicache_cap_27b()
                    else:
                        cap = hicache_max(); h_new = cap if cap >= 8 else 8
            with lock:
                if st["job"]: return self.out(409, {"err": "busy", "job": st["job"]})
                st.update(hicache_gb=h_new, context=c_new)
                same = model is None or model == st["active"]
                if same and m: st["mode"] = mode; atomic_write(C + "/mode", mode)
                apply_runtime(); save_cfg()
                if same and complete(st["active"]): stop(); launch()
            if same: return self.out(200, {"mode": st["mode"], "hicache_gb": h_new, "context_length": c_new, "model": st["active"], "pid": st["proc"] and st["proc"].pid})
            if not start_job(model, mode): return self.out(409, {"err": "busy", "job": st["job"]})
            self.out(202, {"switching_to": model, "mode": mode, "hicache_gb": h_new, "context_length": c_new, "downloaded": complete(model)})
        elif u.path == "/upgrade":
            ref = q.get("ref", [""])[0]
            if not TAG_RE.fullmatch(ref): return self.out(400, {"err": "ref must be a release tag vN.N or vN.N.N"})
            verified = False
            if REPO_URL.startswith("https://"):
                env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "PENNY_API_KEY", "TS_AUTHKEY", "HF_TOKEN")}
                env["GIT_TERMINAL_PROMPT"] = "0"
                try:
                    r = subprocess.run(["git", "ls-remote", "--tags", REPO_URL, "refs/tags/" + ref], capture_output=True, text=True, timeout=60, env=env)
                except (OSError, subprocess.TimeoutExpired): r = None
                if r is not None and r.returncode == 0:
                    if not any(line.split("\t")[1:] == ["refs/tags/" + ref] for line in r.stdout.splitlines() if "\t" in line):
                        return self.out(400, {"err": "tag not found"})
                    verified = True
            tmp = REF_PATH + ".tmp"
            with open(tmp, "w") as f: f.write(ref + "\n")
            os.replace(tmp, REF_PATH)
            print(f"PENNY: upgrade ref {ref} verified={verified} (next reboot)", flush=True)
            self.out(200, {"ref": ref, "verified": verified, "effect": "next reboot"})
        else: self.out(404, {})

start_job(st["active"], st["mode"])
BIND = os.environ.get("PENNY_BIND_HOST") or "0.0.0.0"
if BIND not in ("127.0.0.1", "0.0.0.0"):
    print("PENNY: WARN bad PENNY_BIND_HOST, using 0.0.0.0", flush=True); BIND = "0.0.0.0"
print(f"PENNY: ctl listening {BIND}:{PORT} active={st['active']} mode={st['mode']} hicache={st['hicache_gb']} context={st['context']}", flush=True)
http.server.ThreadingHTTPServer((BIND, PORT), H).serve_forever()
