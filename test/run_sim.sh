#!/usr/bin/env bash
# shellcheck disable=SC2015  # ok() always returns 0, so A && ok || bad is safe here
# Full-flow simulation of the v5 scripts with stubs (no GPU, no real model, no Vast). Usage: bash test/run_sim.sh /path/to/fakeroot
# fakeroot = upstream configs/pennyroyal/* from pennyroyal-v3.0.2 (chat template, FR-Spec map, adaptive config, helpers).
set -uo pipefail
V5=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); T=$V5/test
UPCFG=${1:?fakeroot with configs/pennyroyal}; TOK=${2:?real tokenizer.json (sha 0997f410...)}
W=$(mktemp -d /tmp/pv5sim.XXXX); C=$W/cache; mkdir -p "$C"
PASS=0; FAIL=0
ok() { echo "PASS $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL+1)); }
chk() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
ORCA=jpezzulli/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4@f24d2b68ff2814f24455ae86717be276619b5664
DEAL=dealignai/Qwen3.8-Flash-Next-ABLITERATED-NVFP4@be794b990578ef3031eccf9f28e675a289a09ee9
BADTOK=testorg/BadTok-NVFP4@1111111111111111111111111111111111111111
HUGE=testorg/Huge-NVFP4@2222222222222222222222222222222222222222
KEY="sk-test-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
GHT="github_pat_FAKE$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# --- fake image: REPO_ROOT with upstream configs, stub sglang/python; fake HF data + API; scripts repo ---
R=$W/root; cp -r "$UPCFG" "$R"; mkdir -p "$R/.venv/bin"
cp "$T/fake_sglang.py" "$R/.venv/bin/sglang"; cp "$T/fake_python.sh" "$R/.venv/bin/python"; chmod +x "$R/.venv/bin/"*
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm fake
H=$W/hf; for n in OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4 Qwen3.8-Flash-Next-ABLITERATED-NVFP4 BadTok-NVFP4; do
  mkdir -p "$H/$n"; echo '{"architectures":["fake"]}' > "$H/$n/config.json"; echo '{}' > "$H/$n/model.safetensors.index.json"
  head -c 1000000 /dev/urandom > "$H/$n/model-00001-of-00001.safetensors"; cp "$TOK" "$H/$n/tokenizer.json"; done
echo '{"different":1}' > "$H/BadTok-NVFP4/tokenizer.json"
printf '%s\n' "$ORCA" "$DEAL" "$BADTOK" "$HUGE" > "$W/allow.test"
BARE=$W/remote.git; git init -q --bare "$BARE"; SRC=$W/src; mkdir -p "$SRC"
cp -r "$V5/boot.sh" "$V5/ctl.py" "$V5/bootstrap.sh" "$V5/models.allow" "$V5/upstream" "$SRC/"
git -C "$SRC" init -q -b main && git -C "$SRC" add -A && git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm v5 && git -C "$SRC" push -q "$BARE" main
SHA=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" -c user.email=t@t -c user.name=t tag -a v5.1 -m v5.1 && git -C "$SRC" push -q "$BARE" v5.1
URL=https://github.com/0x458/penny-scripts.git
printf '[url "%s"]\n\tinsteadOf = %s\n' "$BARE" "$URL" > "$C/.gitconfig"   # bootstrap sets HOME=$C; maps the https URL to the local bare repo

export PENNY_CACHE=$C CACHE_BASE=$C PENNY_REPO_URL=$URL PENNY_REPO_REF=v5.1 PENNY_API_KEY=$KEY GH_TOKEN=$GHT PENNY_RAM_GB=189 \
  PENNY_PY=python3 PENNY_HF_BIN=$T/fake_hf.sh HF_ENDPOINT=http://127.0.0.1:18080 REPO_ROOT=$R PENNY_CTL_PORT=18002 \
  PENNY_ALLOW_FILE=$W/allow.test FAKE_ARGV_OUT=$W/argv.jsonl FAKE_HF_DATA=$H FAKE_HF_LOG=$W/hf.log PENNY_DISK_RESERVE_GB=1 \
  PENNY_DL_RETRY_DELAY=1 PENNY_RESTART_DELAY=1 PENNY_MAX_RESTARTS=3 FAKE_HF_FLAKY_DIR=$W/flaky FAKE_CRASH_FILE=$W/crash
mkdir -p "$W/flaky"; touch "$W/flaky/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4"   # first Orca download comes back incomplete
PENNY_BOOTSTRAP_B64=$(base64 -w0 "$V5/bootstrap.sh"); export PENNY_BOOTSTRAP_B64
python3 "$T/fake_hf_api.py" 18080 & APIPID=$!
trap 'kill $APIPID 2>/dev/null; pkill -f "$W/" 2>/dev/null' EXIT
CTL=http://127.0.0.1:18002; A=(-H "Authorization: Bearer $KEY")
st() { curl -s -m 5 "${A[@]}" "$CTL/status"; }
waitphase() { for _ in $(seq 60); do st | grep -q "\"phase\": \"$1\"" && return 0; sleep 1; done; return 1; }
nargv() { wc -l < "$W/argv.jsonl" 2>/dev/null || echo 0; }
waitargv() { local n=$1; for _ in $(seq 60); do (( $(nargv) > n )) && sleep 0.5 && return 0; sleep 0.5; done; return 1; }
lastarg() { tail -1 "$W/argv.jsonl" 2>/dev/null | python3 -c "import json,sys;a=json.load(sys.stdin);k=sys.argv[1];print(a[a.index(k)+1] if k in a else 'ABSENT')" "$1" 2>/dev/null; }

echo "=== 1. boot like Vast: exec bash -c 'echo \$PENNY_BOOTSTRAP_B64 | base64 -d > /cache/bootstrap.sh && exec bash /cache/bootstrap.sh'"
bash -c 'echo "$PENNY_BOOTSTRAP_B64" | base64 -d > "$PENNY_CACHE/bootstrap.sh" && exec bash "$PENNY_CACHE/bootstrap.sh"' > "$W/container.log" 2>&1 &
BOOT=$!
chk "server up in plain mode (default)" waitphase serving:plain
grep "PENNY" "$W/container.log" | sed "s|$W|\$W|g" | head -12
chk "scripts fetched from repo at tag v5.1 (= $SHA)" grep -q "fetched $URL@v5.1 -> $SHA" "$C/logs/bootstrap.log"
chk "incomplete download retried (attempt 1 failed: incomplete)" grep -q "download attempt 1 failed (incomplete" "$W/container.log"
chk "second attempt completed -> .complete" grep -q "model download done" "$W/container.log"
chk "download used pinned revision f24d2b68" grep -q -- "--revision f24d2b68ff2814f24455ae86717be276619b5664" "$W/hf.log"
chk ".complete written with spec" grep -q "$ORCA" "$C/models/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4/.complete"
chk "frspec tokenizer check ok on Orca" grep -q "tokenizer_frspec_ok=True" "$W/container.log"
echo "--- launch argv (plain):"; tail -1 "$W/argv.jsonl" | sed "s|$W|\$W|g; s|$KEY|<KEY>|g" | cut -c1-900
[[ $(lastarg --model-path) == "$C/models/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4" ]] && ok "--model-path = pinned model dir" || bad "--model-path $(lastarg --model-path)"
[[ $(lastarg --api-key) == "$KEY" ]] && ok "--api-key passed" || bad "--api-key"
[[ $(lastarg --served-model-name) == flash-next ]] && ok "--served-model-name flash-next" || bad served
[[ $(lastarg --hicache-size) == 48 ]] && ok "--hicache-size 48 (RAM 189 GB)" || bad "hicache $(lastarg --hicache-size)"
[[ $(lastarg --speculative-token-map) == ABSENT ]] && ok "plain: no FR-Spec map" || bad "plain has map"
[[ $(lastarg --hicache-storage-backend) == ABSENT ]] && ok "NIXL off: no storage backend args" || bad nixl
[[ $(lastarg --port) == 8001 && $(lastarg --host) == 0.0.0.0 ]] && ok "--host 0.0.0.0 --port 8001" || bad port
chk "NIXL off message in server log" grep -q "NIXL disk tier: off" "$C/logs/server-plain.log"
chk "tailscale skipped without TS_AUTHKEY" grep -q "TS_AUTHKEY unset, skipping tailscale" "$W/container.log"

echo "=== 2. api key masking"
chk "fake SGLang really printed server_args (masked)" grep -q "api_key='<API_KEY>'" "$W/container.log"
if grep -rqF -- "$KEY" "$W/container.log" "$C/logs"; then bad "API key leaked in logs: $(grep -rlF -- "$KEY" "$W/container.log" "$C/logs" | sed "s|$W|\$W|g")"; else ok "API key absent from container stdout + all /cache/logs"; fi
curl -s "${A[@]}" "$CTL/log?f=server&n=200" | grep -qF -- "$KEY" && bad "key in /log" || ok "key absent from /log output"
if grep -rqF -- "$GHT" "$W" --exclude-dir=remote.git 2>/dev/null; then bad "GH_TOKEN on disk: $(grep -rlF -- "$GHT" "$W")"; else ok "GH_TOKEN not written anywhere under \$W"; fi
CPID=$(pgrep -f "python3 .*penny-vast/ctl.py" | head -1)
tr '\0' '\n' < "/proc/$CPID/environ" | grep -q '^GH_TOKEN=' && bad "GH_TOKEN in ctl env" || ok "GH_TOKEN unset in ctl.py env (pid $CPID)"

echo "=== 3. auth + malicious input"
for c in "-X GET $CTL/status" "-X POST $CTL/mode?m=frspec" "-X POST $CTL/switch?model=$DEAL"; do
  # shellcheck disable=SC2086
  code=$(curl -s -o /dev/null -w '%{http_code}' $c); [[ $code == 401 ]] && ok "no token -> 401 ($c)" || bad "no token $code ($c)"; done
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer wrong" "$CTL/status"); [[ $code == 401 ]] && ok "wrong token -> 401" || bad "wrong token $code"
for m in "../../etc@$(printf 'a%.0s' {1..40})" "jpezzulli/..@f24d2b68ff2814f24455ae86717be276619b5664" "jpezzulli%2F..%2F..%2Fetc@f24d2b68ff2814f24455ae86717be276619b5664" \
         "jpezzulli/x;rm%20-rf%20/@f24d2b68ff2814f24455ae86717be276619b5664" "jpezzulli/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4@main" \
         "evil/Qwen3.8-Flash-Next-NVFP4@f24d2b68ff2814f24455ae86717be276619b5664" "%24(id)/x@f24d2b68ff2814f24455ae86717be276619b5664" ""; do
  r=$(curl -s -w ' %{http_code}' -X POST "${A[@]}" "$CTL/switch?model=$m"); [[ $r == *" 400" ]] && ok "reject switch model=$m -> $r" || bad "switch $m -> $r"; done
r=$(curl -s -w ' %{http_code}' -X POST "${A[@]}" "$CTL/mode?m=bash"); [[ $r == *" 400" ]] && ok "reject mode=bash -> $r" || bad "mode bash $r"
r=$(curl -s -w ' %{http_code}' "${A[@]}" "$CTL/log?f=../../etc/passwd"); [[ $r == *" 400" ]] && ok "reject log f=../../etc/passwd" || bad "log $r"
chk "no dirs created outside models root" test ! -e "$C/etc" -a ! -e "$W/etc"

echo "=== 4. FR-Spec on/off"
N=$(nargv); curl -s -X POST "${A[@]}" "$CTL/mode?m=frspec"; echo
chk "frspec serving" waitphase serving:frspec
chk "frspec sglang started (new argv)" waitargv "$N"
chk "server process alive (rc null)" bash -c "curl -s -H 'Authorization: Bearer $KEY' $CTL/status | grep -q '\"rc\": null'"
[[ $(lastarg --speculative-token-map) == "$R/configs/pennyroyal/frspec/flash-next-64k.pt" ]] && ok "frspec: --speculative-token-map pinned map" || bad "map $(lastarg --speculative-token-map)"
chk "frspec start file passed upstream tokenizer check" grep -q "Verifying the pinned FR-Spec map, tokenizer" "$C/logs/server-frspec.log"
curl -s -X POST "${A[@]}" "$CTL/mode?m=plain"; echo
chk "back to plain" waitphase serving:plain
[[ $(grep -c "SGLang exited" "$W/container.log") == 0 ]] && ok "intentional stops (mode switches) not counted as crashes" || bad "mode switch counted as crash"

echo "=== 4b. crash -> limited auto-restart"
echo 2 > "$W/crash"; N=$(nargv); curl -s -X POST "${A[@]}" "$CTL/mode?m=plain" >/dev/null
for _ in $(seq 40); do st | grep -q '"restarts": 2' && st | grep -q '"phase": "serving:plain"' && st | grep -q '"rc": null' && break; sleep 1; done
st | grep -q '"restarts": 2' && ok "2 crashes -> 2 automatic restarts, now serving: $(grep -c 'SGLang exited rc=3; restart' "$W/container.log") restart lines" || bad "restart: $(st)"
echo 9 > "$W/crash"; curl -s -X POST "${A[@]}" "$CTL/mode?m=plain" >/dev/null
for _ in $(seq 40); do st | grep -q '"phase": "crashed' && break; sleep 1; done
st | grep -q '"phase": "crashed rc=3"' && ok "crash loop stops after 3 restarts: $(st | python3 -c 'import json,sys;print(json.load(sys.stdin)["err"])')" || bad "crash loop: $(st)"
rm -f "$W/crash"; curl -s -X POST "${A[@]}" "$CTL/mode?m=plain" >/dev/null
for _ in $(seq 20); do st | grep -q '"restarts": 0' && st | grep -q '"phase": "serving:plain"' && break; sleep 1; done
st | grep -q '"restarts": 0' && ok "manual /mode resets restart budget and serves again" || bad "reset: $(st)"

echo "=== 5. whitelist switch"
N=$(nargv); curl -s -X POST "${A[@]}" "$CTL/switch?model=$DEAL&m=plain"; echo
for _ in $(seq 30); do st | grep -q "\"active\": \"$DEAL\"" && break; sleep 1; done
chk "switched to dealignai (plain)" waitphase serving:plain
chk "dealignai sglang started (new argv)" waitargv "$N"
[[ $(lastarg --model-path) == "$C/models/Qwen3.8-Flash-Next-ABLITERATED-NVFP4" ]] && ok "dealignai model dir launched" || bad "switch argv $(lastarg --model-path)"
chk "dealignai .complete" test -f "$C/models/Qwen3.8-Flash-Next-ABLITERATED-NVFP4/.complete"
curl -s -X POST "${A[@]}" "$CTL/switch?model=$HUGE"; echo; sleep 3
st | grep -q '"err": "disk: need' && ok "huge model refused by disk check, old server kept: $(st | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["err"], "| phase", d["phase"], "| active", d["active"][:30])')" || bad "disk check: $(st)"
curl -s -X POST "${A[@]}" "$CTL/switch?model=$BADTOK&m=frspec"; echo
for _ in $(seq 30); do st | grep -q "\"active\": \"$BADTOK\"" && break; sleep 1; done
chk "bad tokenizer -> forced plain" waitphase serving:plain
r=$(curl -s -w ' %{http_code}' -X POST "${A[@]}" "$CTL/mode?m=frspec"); [[ $r == *" 409" ]] && ok "frspec refused for bad tokenizer: $r" || bad "frspec badtok $r"
curl -s -X POST "${A[@]}" "$CTL/switch?model=$ORCA&m=plain" >/dev/null
for _ in $(seq 30); do st | grep -q "\"active\": \"$ORCA\"" && break; sleep 1; done; waitphase serving:plain
echo "--- /models:"; curl -s "${A[@]}" "$CTL/models" | python3 -c "import json,sys;d=json.load(sys.stdin);print('active',d['active'][:40]);[print(' ',m) for m in d['models']]"
kill "$BOOT" 2>/dev/null; pkill -f "penny-vast/ctl.py" ; pkill -f "$R/.venv/bin/sglang"; sleep 1

echo "=== 6. HiCache cap by rented RAM"
C2=$W/c2; mkdir -p "$C2"; cp -r "$C/penny-vast" "$C2/"
PENNY_CACHE=$C2 PENNY_RAM_GB=128 PENNY_CTL_PORT=18003 timeout 5 bash "$C2/penny-vast/boot.sh" > "$W/c2.log" 2>&1
chk "RAM 128 -> HICACHE_SIZE_GB=28" grep -q '^HICACHE_SIZE_GB=28$' "$C2/start-plain.sh"
grep "HiCache" "$W/c2.log"
env -u PENNY_RAM_GB PENNY_CACHE="$C2" timeout 5 bash "$C2/penny-vast/boot.sh" > "$W/c4.log" 2>&1; rc=$?
[[ $rc != 0 ]] && grep -q "FATAL PENNY_RAM_GB is required" "$W/c4.log" && ok "PENNY_RAM_GB unset -> refuses to start (rc=$rc)" || bad "ram unset rc=$rc"
PENNY_CACHE=$C2 PENNY_RAM_GB=100 timeout 5 bash "$C2/penny-vast/boot.sh" > "$W/c3.log" 2>&1; rc=$?
[[ $rc != 0 ]] && grep -q "too small" "$W/c3.log" && ok "RAM 100 -> refuses to start (rc=$rc): $(grep FATAL "$W/c3.log")" || bad "ram 100 rc=$rc"
pkill -f "c2/penny-vast/ctl.py" 2>/dev/null; pkill -f "$R/.venv/bin/sglang" 2>/dev/null

echo "=== 7. bootstrap fallbacks"
# 7a token travels as an http header, never in argv/URL/logs; fetch fails -> uses cached copy
python3 "$T/auth_capture.py" 18081 "$W/auth.txt" & CAP=$!
printf '[url "http://127.0.0.1:18081/x.git"]\n\tinsteadOf = %s\n' "$URL" > "$C/.gitconfig"; sleep 0.5
env -u PENNY_API_KEY bash "$C/bootstrap.sh" > "$W/b7a.log" 2>&1
want="Basic $(printf 'x-access-token:%s' "$GHT" | base64 -w0)"
grep -qxF "$want" "$W/auth.txt" && ok "GH_TOKEN sent as 'Authorization: Basic base64(x-access-token:TOKEN)'" || bad "auth header: $(sort -u "$W/auth.txt" | cut -c1-20)"
grep -q "WARN: using cached copy $SHA" "$C/logs/bootstrap.log" && ok "fetch failed -> cached copy used" || bad "no cached fallback"
grep -qF -- "$GHT" "$W/b7a.log" "$C/logs/bootstrap.log" && bad "token in bootstrap output" || ok "token not in bootstrap output"
kill $CAP
# 7b no cache, no embedded -> clear FATAL, exit 1
rm -rf "$C/penny-vast"; env -u PENNY_API_KEY bash "$C/bootstrap.sh" > "$W/b7b.log" 2>&1; rc=$?
[[ $rc == 1 ]] && grep -q FATAL "$W/b7b.log" && ok "nothing available -> exit 1: $(grep FATAL "$W/b7b.log" | cut -c1-100)" || bad "7b rc=$rc"
# 7c embedded fallback
PENNY_BOOT_B64=$(base64 -w0 "$V5/boot.sh") PENNY_CTL_B64=$(base64 -w0 "$V5/ctl.py") env -u PENNY_API_KEY bash "$C/bootstrap.sh" > "$W/b7c.log" 2>&1
grep -q "using embedded" "$W/b7c.log" && ok "embedded PENNY_BOOT_B64/PENNY_CTL_B64 fallback used" || bad 7c
# 7d http URL refused
PENNY_REPO_URL=http://example.com/x.git bash "$C/bootstrap.sh" > "$W/b7d.log" 2>&1 && bad "http accepted" || ok "non-https repo URL refused"
kill $APIPID 2>/dev/null
echo "=== 8. vast search query (offline parse with the installed vastai CLI parser; no API call)"
VPY=/home/box/.local/share/pipx/venvs/vastai/bin/python
# shellcheck disable=SC2016
QUERY=$(sed -n 's/^QUERY="\(.*\)"$/\1/p' "$V5/vast/create-instance.sh.example" | sed 's/\$GEO/JP/')
if [[ -x $VPY ]]; then
  PQ=$("$VPY" -c 'import json,sys
from vastai.api.query import parse_query, offers_fields, offers_alias, offers_mult
print(json.dumps(parse_query(sys.argv[1], {"verified":{"eq":True},"external":{"eq":False},"rentable":{"eq":True}}, offers_fields, offers_alias, offers_mult)))' "$QUERY")
  echo "$PQ"
  echo "$PQ" | grep -q '"gpu_ram": {"gte": 90000.0}' && ok "gpu_ram>=90 parsed (x1000 -> MB)" || bad gpu_ram
  echo "$PQ" | grep -q '"verified"' && bad "verified filter still present" || ok "verified=any removes the default verified=true"
  grep -q -- "--limit 200" "$V5/vast/create-instance.sh.example" && grep -q '"Max-Q" not in g' "$V5/vast/create-instance.sh.example" && ok "template: --limit 200 + python Max-Q exclusion" || bad template
  grep -q "PENNY_REPO_REF=v5.1" "$V5/vast/create-instance.sh.example" && grep -q "PENNY_REPO_REF=v5.1\|v5.1" "$V5/README.md" && ! grep -q "PENNY_REPO_REF=main" "$V5/vast/create-instance.sh.example" "$V5/README.md" && ok "template + README pin tag v5.1" || bad "tag alignment"
else echo "SKIP vastai CLI not installed"; fi

echo "=== 9. tailscale block"
TSOUT=$(bash "$T/ts_test.sh" "$V5/boot.sh"); echo "$TSOUT" | grep -E "^\[|RESULT"
TP=$(echo "$TSOUT" | sed -n 's/^=== TS RESULT: \([0-9]*\) passed, \([0-9]*\) failed/\1/p'); TF=$(echo "$TSOUT" | sed -n 's/^=== TS RESULT: \([0-9]*\) passed, \([0-9]*\) failed/\2/p')
PASS=$((PASS + TP)); FAIL=$((FAIL + TF))
echo "=== RESULT: $PASS passed, $FAIL failed (workdir $W)"
