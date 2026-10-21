#!/usr/bin/env bash
# Penny v5 boot (Penny Royal v3.0.2 + jpezzulli Orca NVFP4 @f24d2b68 on one RTX PRO 6000).
# Prepares both start files (plain = default, frspec) from the pinned upstream copies, optional Tailscale,
# then runs ctl.py (:8002), which downloads the pinned model, writes .complete and starts SGLang (:8001).
# Generated start files default PENNY_REASONING_EFFORT to xhigh, and inject the upstream YaRN
# factor-2.0 override only when context is 524288 (the native window is 262144).
# Env (first boot): PENNY_API_KEY, PENNY_RAM_GB (rented RAM, caps HiCache). Optional: PENNY_HICACHE_GB, PENNY_MODE,
#      PENNY_MODEL, TS_AUTHKEY, TS_TAGS (default empty; --advertise-tags only when set),
#      PENNY_PUBLIC_BIND=1 (keep 0.0.0.0 even when Tailscale is up).
# After first boot, /cache/config.json and /cache/penny-ref win over the frozen Vast env.
# A healthy SGLang (/health) records the running ref in /cache/penny-ref-good and snapshots the scripts.
# bootstrap.sh rolls a new ref back to that snapshot when SGLang does not come up. The model stays put.
set -euo pipefail
C=${PENNY_CACHE:-/cache}
export HOME=$C PENNY_CACHE=$C
D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PY=${PENNY_PY:-/opt/pennyroyal/.venv/bin/python}
UP_REF=pennyroyal-v3.0.2
declare -A UP_SHA=(
  [start-flash-next-frspec.sh]=db2dfdd7d3ae15f77a6dd3dc32316c933ff5d49e0e218ed109dc5e3e09ee505d
  [start-flash-next.sh]=799c70290bf95ee83e2e98530e594b9f5f24b174d6acb298b1111aaee2fceddd
)
: "${PENNY_API_KEY:?set PENNY_API_KEY}"
mkdir -p "$C/logs"
export PENNY_MODELS_ROOT=${PENNY_MODELS_ROOT:-$C/models}
mkdir -p "$PENNY_MODELS_ROOT"
exec > >(tee -a "$C/logs/boot.log") 2>&1
echo "PENNY: boot v5 $(date -u) scripts=$(cat "$D/.penny-head" 2>/dev/null || echo embedded)"

# HiCache: Vast/gVisor cgroup limits can be far above what was rented (538 GB seen vs 189 GB rented), so cap by
# PENNY_RAM_GB. Budget: RAM PLE ~51 GB + process/pinned buffers ~40 GB => HiCache <= RAM - 100.
# Default wanted size is 48. /cache/config.json may ask for more; it is still capped by RAM - 100.
# /cache/config.json (POST /config) overrides the first-boot env and survives reboot.
CFG_H=""; CFG_C=""
if [[ -f $C/config.json ]]; then
  read -r CFG_H CFG_C < <("$PY" -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
if not isinstance(d, dict):
    raise SystemExit
h, c = d.get("hicache_gb"), d.get("context_length")
print(h if isinstance(h, int) and not isinstance(h, bool) else "", c if isinstance(c, int) and not isinstance(c, bool) else "")
' "$C/config.json") || true
fi
if [[ $CFG_H =~ ^[1-9][0-9]{0,3}$ ]]; then WANT=$CFG_H; else WANT=${PENNY_HICACHE_GB:-48}; fi
RAM=${PENNY_RAM_GB:-}
[[ -n $RAM ]] || { echo "PENNY: FATAL PENNY_RAM_GB is required (the offer's RAM in GB; the cgroup/MemTotal value is not the rental)" >&2; exit 1; }
[[ $WANT =~ ^[1-9][0-9]{0,3}$ && $RAM =~ ^[1-9][0-9]{0,4}$ ]] || { echo "PENNY: FATAL bad PENNY_HICACHE_GB/PENNY_RAM_GB" >&2; exit 1; }
HICACHE_GB=$(( RAM - 100 < WANT ? RAM - 100 : WANT ))
(( HICACHE_GB >= 8 )) || { echo "PENNY: FATAL rented RAM ${RAM} GB too small (need >=108 GB for PLE + HiCache)" >&2; exit 1; }
export PENNY_HICACHE_GB=$HICACHE_GB
CONTEXT=524288
if [[ $CFG_C =~ ^(65536|131072|262144|524288)$ ]]; then CONTEXT=$CFG_C
elif [[ -n $CFG_C ]]; then echo "PENNY: WARN bad context_length in config, using 524288"; fi
export PENNY_CONTEXT_LENGTH=$CONTEXT
echo "PENNY: HiCache ${HICACHE_GB} GB (rented RAM ${RAM} GB, wanted ${WANT}); context ${CONTEXT}; disk free $(df -BG --output=avail "$PENNY_MODELS_ROOT" | tail -1 | tr -d ' ')"

# Upstream hardcodes two things we do not want at the usual 262144 context.
# reasoning-effort.sh keeps medium when PENNY_REASONING_EFFORT is unset; default xhigh here.
# YaRN factor 2.0 (original_max_position_embeddings 262144) exists only to stretch that
# native window to 524288. At 65536, 131072, and 262144 it rescales RoPE for no extra
# room and hurts short text, so the launch omits --json-model-override-args. 524288 keeps it.
# An explicit PENNY_REASONING_EFFORT still wins. A request reasoning_effort still wins later
# in OpenAIServingChat; the start file only sets the server default.
rewrite_start_quality() {
  local file=$1 line tmp
  local old='--json-model-override-args "$TARGET_OVERRIDES"'
  local new='"${JSON_MODEL_OVERRIDE_ARGS[@]}"'
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      'source "$IMAGE_CONFIGS/reasoning-effort.sh"')
        cat >> "$tmp" <<'EOF'
# reasoning-effort.sh uses medium when PENNY_REASONING_EFFORT is unset or empty.
# Default xhigh. An explicit PENNY_REASONING_EFFORT still wins. A request
# reasoning_effort still wins in OpenAIServingChat; this is only the server default.
: "${PENNY_REASONING_EFFORT:=xhigh}"
export PENNY_REASONING_EFFORT
source "$IMAGE_CONFIGS/reasoning-effort.sh"
EOF
        ;;
      TARGET_OVERRIDES=*)
        cat >> "$tmp" <<'EOF'
# Native context is 262144. YaRN factor 2.0 (original_max_position_embeddings
# 262144) is the 2x extension to 524288 and nothing else. Any other allowed
# context, including the usual 262144, injects no override.
if [[ "$CONTEXT_LENGTH" == 524288 ]]; then
  TARGET_OVERRIDES='{"text_config":{"rope_parameters":{"mrope_interleaved":true,"mrope_section":[11,11,10],"rope_type":"yarn","rope_theta":10000000,"partial_rotary_factor":0.25,"factor":2.0,"original_max_position_embeddings":262144}}}'
  JSON_MODEL_OVERRIDE_ARGS=(--json-model-override-args "$TARGET_OVERRIDES")
else
  TARGET_OVERRIDES=''
  JSON_MODEL_OVERRIDE_ARGS=()
fi
EOF
        ;;
      *)
        # Only the launch line. The 524288 arm above keeps the literal flag
        # that fills JSON_MODEL_OVERRIDE_ARGS; a global replace would empty it.
        if [[ $line == *"$old"* ]]; then line=${line//"$old"/"$new"}; fi
        printf '%s\n' "$line" >> "$tmp"
        ;;
    esac
  done < "$file"
  mv -f "$tmp" "$file"
}

for mode in frspec plain; do
  src=start-flash-next.sh; [[ $mode == frspec ]] && src=start-flash-next-frspec.sh
  f=$D/upstream/$src
  if [[ ! -f $f ]]; then   # embedded fallback has no upstream/ copy
    f=$C/upstream-$src
    curl -fsSL --retry 3 "https://raw.githubusercontent.com/jpezzulli/sglang-rtxpro6000/$UP_REF/docker/pennyroyal/launch/config/$src" -o "$f"
  fi
  read -r sha _ < <(sha256sum "$f")
  [[ $sha == "${UP_SHA[$src]}" ]] || { echo "PENNY: FATAL $src sha256 $sha != pinned $UP_REF" >&2; exit 1; }
  out=$C/start-$mode.sh
  # shellcheck disable=SC2016  # $PENNY_* must stay literal in the generated start file
  sed -e 's|^TARGET_MODEL=.*|TARGET_MODEL="${PENNY_MODEL_DIR:?PENNY_MODEL_DIR not set}"|' \
      -e 's|^NIXL=on$|NIXL=off|' \
      -e 's|^HICACHE_SIZE_GB=.*|HICACHE_SIZE_GB="${PENNY_HICACHE_GB:?PENNY_HICACHE_GB not set}"|' \
      -e 's|^CONTEXT_LENGTH=.*|CONTEXT_LENGTH="${PENNY_CONTEXT_LENGTH:-524288}"|' \
      -e 's|--host 0\.0\.0\.0 --port 8001|--host "${PENNY_BIND_HOST:-0.0.0.0}" --port 8001|' \
      -e 's|--served-model-name pennyroyal \\|--served-model-name flash-next --api-key "$PENNY_API_KEY" \\|' "$f" > "$out"
  rewrite_start_quality "$out"
  # Every patch must land exactly once. The upstream YaRN flag must be gone;
  # the factor-2.0 JSON may remain only inside the 524288 arm.
  # shellcheck disable=SC2016
  for pat in '^TARGET_MODEL="\$\{PENNY_MODEL_DIR:\?' '^NIXL=off$' '^HICACHE_SIZE_GB="\$\{PENNY_HICACHE_GB:\?PENNY_HICACHE_GB not set\}"$' '^CONTEXT_LENGTH="\$\{PENNY_CONTEXT_LENGTH:-524288\}"$' 'served-model-name flash-next --api-key "\$PENNY_API_KEY"' '--host "\$\{PENNY_BIND_HOST:-0\.0\.0\.0\}" --port 8001' ': "\$\{PENNY_REASONING_EFFORT:=xhigh\}"' 'if \[\[ "\$CONTEXT_LENGTH" == 524288 \]\]; then' 'JSON_MODEL_OVERRIDE_ARGS=\(\)' '--context-length "\$CONTEXT_LENGTH" "\$\{JSON_MODEL_OVERRIDE_ARGS\[@\]\}"'; do
    [[ $(grep -cE -- "$pat" "$out") == 1 ]] || { echo "PENNY: FATAL patch check failed in $out: $pat" >&2; exit 1; }
  done
  if grep -qF -- '--context-length "$CONTEXT_LENGTH" --json-model-override-args "$TARGET_OVERRIDES"' "$out"; then
    echo "PENNY: FATAL unconditional YaRN flag remains in $out" >&2
    exit 1
  fi
  [[ $(grep -cF 'rope_type":"yarn"' "$out") == 1 ]] || { echo "PENNY: FATAL YaRN override must appear once, only in the 524288 arm, in $out" >&2; exit 1; }
  bash -n "$out"
done
echo "PENNY: start files ready (frspec, plain)"

# Optional Tailscale (userspace; image has no root/TUN). Only with TS_AUTHKEY; key passed via a 0600 file, not argv.
# Every step returns explicitly: set -e does NOT apply inside a function/subshell used in an if/|| context.
# Vast -p cannot target the tailnet (no TUN). When Tailscale is up, bind 127.0.0.1 and serve both ports unless
# PENNY_PUBLIC_BIND=1. Without TS_AUTHKEY, bind 0.0.0.0 and WARN. A failed Tailscale stays on 0.0.0.0.
# An offline node that still holds TS_HOSTNAME makes `tailscale up` rename this one (vast-penny-1). Warn; do not exit.
ts_note_hostname() {
  local expect=${TS_HOSTNAME:-vast-penny} parsed got="" dns="" ip="" label="" show="" mismatch=0 py=$PY probe=""
  # ts_test sets PENNY_PY=true so boot does not start ctl.py. A real interpreter is required to read status JSON.
  probe=$("$py" -c 'print("pyok")' 2>/dev/null || true)
  if [[ $probe != pyok ]]; then py=python3; fi
  parsed=$("$py" -c 'import json,sys
raw=sys.argv[1] if len(sys.argv)>1 else ""
try: d=json.loads(raw) if raw.strip() else {}
except Exception: d={}
s=d.get("Self") if isinstance(d,dict) else None
if not isinstance(s,dict): s={}
host=s.get("HostName") if isinstance(s.get("HostName"),str) else ""
dns=s.get("DNSName") if isinstance(s.get("DNSName"),str) else ""
ips=s.get("TailscaleIPs") if isinstance(s.get("TailscaleIPs"),list) else []
ip=",".join(x for x in ips if isinstance(x,str) and x)
print(host); print(dns); print(ip)' "$1" 2>/dev/null) || parsed=""
  { IFS= read -r got || true; IFS= read -r dns || true; IFS= read -r ip || true; } <<< "$parsed"
  label=${dns%.}; label=${label%%.*}
  [[ -n $got ]] || got=$label
  if [[ -n $got && ${got,,} != "${expect,,}" ]]; then mismatch=1; fi
  if [[ -n $label && ${label,,} != "${expect,,}" ]]; then mismatch=1; fi
  if [[ $mismatch == 0 ]]; then return 0; fi
  show=$got
  if [[ -n $label && ${label,,} != "${expect,,}" ]]; then show=$label; fi
  echo "PENNY: WARN tailscale hostname: asked for ${expect}, got ${show} (DNS ${dns:-unknown}, tailnet IP ${ip:-unknown}). An offline node still holds ${expect}. Delete that node in the Tailscale admin console, or connect clients to this tailnet IP. Boot continues."
  return 0
}
ts_up() {
  local TS=$1 V i state="" stjson="" polls=${PENNY_TS_POLL:-30} tout=${PENNY_TS_TIMEOUT:-150}
  if [[ ! -x $TS/tailscaled || ! -x $TS/tailscale ]]; then
    V=$(curl -fsSL --retry 3 'https://pkgs.tailscale.com/stable/?mode=json' | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["TarballsVersion"])') || { echo "PENNY: tailscale version lookup failed"; return 1; }
    [[ $V =~ ^[0-9][0-9.]*$ ]] || { echo "PENNY: bad tailscale version '$V'"; return 1; }
    curl -fsSL --retry 3 "https://pkgs.tailscale.com/stable/tailscale_${V}_amd64.tgz" -o "$TS/ts.tgz" || { echo "PENNY: tailscale download failed"; return 1; }
    "$PY" -c 'import sys,tarfile,os,shutil
t=tarfile.open(sys.argv[1]); n=0
for m in t.getmembers():
    b=os.path.basename(m.name)
    if b in ("tailscale","tailscaled") and m.isfile():
        with t.extractfile(m) as s, open(os.path.join(sys.argv[2],b),"wb") as o: shutil.copyfileobj(s,o)
        os.chmod(os.path.join(sys.argv[2],b),0o755); n+=1
sys.exit(0 if n==2 else 1)' "$TS/ts.tgz" "$TS" || { echo "PENNY: tailscale unpack failed"; return 1; }
  fi
  nohup "$TS/tailscaled" --tun=userspace-networking --statedir="$TS/state" --socket="$TS/sock" > "$C/logs/tailscaled.log" 2>&1 &
  for ((i = 0; i < polls; i++)); do [[ -S $TS/sock ]] && break; sleep 1; done
  [[ -S $TS/sock ]] || { echo "PENNY: tailscaled socket did not appear in ${polls}s"; return 1; }
  ( umask 077; printf '%s' "$TS_AUTHKEY" > "$TS/authkey" ) || return 1
  # Empty by default. The auth key is not tagged, and `tailscale up --advertise-tags` fails on that key.
  local -a up_cmd
  up_cmd=(--socket="$TS/sock" up --timeout=120s --hostname="${TS_HOSTNAME:-vast-penny}" --auth-key="file:$TS/authkey")
  if [[ -n ${TS_TAGS:-} ]]; then up_cmd+=(--advertise-tags="$TS_TAGS"); fi
  timeout "$tout" "$TS/tailscale" "${up_cmd[@]}"
  i=$?; rm -f "$TS/authkey"
  (( i == 0 )) || { echo "PENNY: tailscale up failed rc=$i"; return 1; }
  for ((i = 0; i < polls; i++)); do
    stjson=$("$TS/tailscale" --socket="$TS/sock" status --json 2>/dev/null || true)
    state=$(printf '%s' "$stjson" | grep -oE '"BackendState":[[:space:]]*"[A-Za-z]+"' | grep -oE '[A-Za-z]+"$' | tr -d '"' || true)
    [[ $state == Running ]] && break; sleep 2
  done
  [[ $state == Running ]] || { echo "PENNY: tailscale BackendState=${state:-unknown}, not Running"; return 1; }
  ts_note_hostname "$stjson"
  timeout "$tout" "$TS/tailscale" --socket="$TS/sock" serve --bg --tcp 8000 tcp://127.0.0.1:8001 || { echo "PENNY: tailscale serve failed"; return 1; }
  timeout "$tout" "$TS/tailscale" --socket="$TS/sock" serve --bg --tcp 8002 tcp://127.0.0.1:8002 || { echo "PENNY: tailscale serve failed"; return 1; }
  echo "PENNY: tailscale up + serve tcp 8000 ok (BackendState=Running)"
}
export PENNY_BIND_HOST=0.0.0.0
if [[ -n ${TS_AUTHKEY:-} ]]; then
  mkdir -p "$C/ts/state"
  if ts_up "$C/ts"; then
    if [[ ${PENNY_PUBLIC_BIND:-} == 1 ]]; then
      echo "PENNY: PENNY_PUBLIC_BIND=1, ports 8001/8002 stay on 0.0.0.0"
    else
      export PENNY_BIND_HOST=127.0.0.1
      echo "PENNY: bind 127.0.0.1 only (tailnet tcp/8000 -> :8001, tcp/8002 -> :8002)"
    fi
  else
    echo "PENNY: WARN tailscale up/serve failed within the timeout; binding 0.0.0.0. This line is in vastai logs <id>. TAILNET=1 publishes no -p, so this fallback is unreachable from outside the container. Recovery: fix Tailscale, then vastai reboot instance <id> (disk and model stay)."
  fi
  rm -f "$C/ts/authkey"
else
  echo "PENNY: TS_AUTHKEY unset, skipping tailscale"
  echo "PENNY: WARN ports 8001/8002 are public plain HTTP"
fi
unset TS_AUTHKEY

# Record the ref only after SGLang answers /health. PENNY_SUPERVISED=1 means bootstrap.sh is watching
# that check and will roll back; this process just becomes ctl.py.
# pennyroyal-v3.0.2 (python/sglang/srt/utils/auth.py) allows every path starting with /health
# even when --api-key is set, so this request carries no key. curl -f treats 401 as not healthy.
# The key stays out of argv and out of this log.
sglang_healthy() { curl -fsS -m 2 "http://127.0.0.1:${PENNY_SGLANG_PORT:-8001}/health" >/dev/null 2>&1; }
atomic_line() {
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || return 1
  printf '%s\n' "$2" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$1"
}
# Only the ref written into this script tree. /cache/penny-ref can name a tag that failed to fetch.
script_ref() {
  local r=""
  [[ -f $D/.penny-ref ]] && r=$(head -n 1 "$D/.penny-ref" | tr -d '[:space:]')
  printf '%s' "$r"
}
swap_in() {
  local dest=$1
  rm -rf "$dest.old"
  if [[ -e $dest ]]; then mv "$dest" "$dest.old"; fi
  if mv "$dest.new" "$dest"; then rm -rf "$dest.old"; return 0; fi
  [[ -e $dest.old ]] && mv "$dest.old" "$dest"
  return 1
}
mark_good() {
  local ref dest=$C/penny-vast-good
  ref=$(script_ref)
  [[ -n $ref ]] || { echo "PENNY: WARN scripts have no .penny-ref; leaving penny-ref-good unchanged"; return 0; }
  rm -rf "$dest.new"
  mkdir -p "$dest.new"
  cp -a "$D/." "$dest.new/"
  swap_in "$dest"
  atomic_line "$C/penny-ref-good" "$ref"
  echo "PENNY: recorded good ref $ref"
}
kill_tree() {
  local pid=$1 c
  [[ -n ${pid:-} ]] || return 0
  for c in $(ps -o pid= --ppid "$pid" 2>/dev/null); do kill_tree "$c"; done
  kill -TERM "$pid" 2>/dev/null || true
}
if [[ ${PENNY_SUPERVISED:-} == 1 ]]; then exec "$PY" "$D/ctl.py"; fi
"$PY" "$D/ctl.py" &
pid=$!
trap 'kill_tree "$pid"; kill -KILL "$pid" 2>/dev/null || true; exit 143' TERM INT
tout=${PENNY_HEALTH_TIMEOUT:-1800}
for ((i = 0; i < tout; i++)); do
  if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; exit $?; fi
  if sglang_healthy; then
    mark_good
    trap - TERM INT
    wait "$pid"
    exit $?
  fi
  sleep 1
done
echo "PENNY: WARN SGLang /health not ready after ${tout}s (scripts ref $(script_ref)); leaving ctl running"
trap - TERM INT
wait "$pid"
exit $?
