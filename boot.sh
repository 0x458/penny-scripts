#!/usr/bin/env bash
# Penny v5 boot (Penny Royal v3.0.2 + jpezzulli Orca NVFP4 @f24d2b68 on one RTX PRO 6000,
# or mode 27b: Qwen3.8-27B AWQ + DFlash2 on one RTX 5090).
# Prepares the start files (plain = default, frspec, and 27b) from the pinned upstream copies, optional Tailscale,
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
  [start-27b-dflash2.sh]=507eaa84668965943f8d759e18849bbadf247c6bf16c5f1e8f17610e6bd3b195
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
CFG_H=""; CFG_C=""; CFG_M=""
if [[ -f $C/config.json ]]; then
  read -r CFG_H CFG_C CFG_M < <("$PY" -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
if not isinstance(d, dict):
    raise SystemExit
h, c, m = d.get("hicache_gb"), d.get("context_length"), d.get("mode")
print(h if isinstance(h, int) and not isinstance(h, bool) else "", c if isinstance(c, int) and not isinstance(c, bool) else "", m if isinstance(m, str) else "")
' "$C/config.json") || true
fi
MODE=${PENNY_MODE:-}
if [[ $CFG_M == plain || $CFG_M == frspec || $CFG_M == 27b ]]; then MODE=$CFG_M; fi
RAM=${PENNY_RAM_GB:-}
[[ -n $RAM ]] || { echo "PENNY: FATAL PENNY_RAM_GB is required (the offer's RAM in GB; the cgroup/MemTotal value is not the rental)" >&2; exit 1; }
if [[ $MODE == 27b ]]; then
  # RTX 5090 budget (see README). Context is a VRAM number, not a host-RAM number.
  # Host RAM under 108 GB cannot pin HiCache: the upstream 27B recipe wants 96 GB,
  # and a ~31 GB box OOMs if that pool is allocated. 0 turns the host tier off.
  [[ $RAM =~ ^[1-9][0-9]{0,4}$ ]] || { echo "PENNY: FATAL bad PENNY_RAM_GB" >&2; exit 1; }
  CONTEXT=${PENNY_27B_CONTEXT_LENGTH:-126784}
  if [[ $CFG_C =~ ^(32768|65536|98304|126784)$ ]]; then CONTEXT=$CFG_C
  elif [[ -n $CFG_C ]]; then echo "PENNY: WARN bad context_length in config, using ${CONTEXT}"; fi
  if [[ $CONTEXT != 32768 && $CONTEXT != 65536 && $CONTEXT != 98304 && $CONTEXT != 126784 ]]; then
    echo "PENNY: WARN bad PENNY_27B_CONTEXT_LENGTH, using 126784"; CONTEXT=126784
  fi
  if (( RAM >= 108 )); then
    CAP=$(( RAM - 100 < 96 ? RAM - 100 : 96 ))
    if [[ $CFG_H == 0 ]]; then H27=0
    elif [[ $CFG_H =~ ^[1-9][0-9]{0,3}$ ]]; then
      H27=$CFG_H
      if (( H27 < 8 || H27 > CAP )); then echo "PENNY: WARN 27B HiCache ${H27} GB outside 8..${CAP}, using ${CAP}"; H27=$CAP; fi
    else H27=$CAP; fi
  else
    H27=0
    if [[ $CFG_H =~ ^[1-9][0-9]{0,3}$ && $CFG_H != 0 ]]; then
      echo "PENNY: WARN 27B HiCache forced off; rented RAM ${RAM} GB is under 108 GB"
    fi
  fi
  export PENNY_27B_HICACHE_GB=$H27 PENNY_27B_CONTEXT_LENGTH=$CONTEXT
  if (( H27 == 0 )); then
    echo "PENNY: 27B HiCache off (rented RAM ${RAM} GB, no pinned host pool); context ${CONTEXT}; disk free $(df -BG --output=avail "$PENNY_MODELS_ROOT" | tail -1 | tr -d ' ')"
  else
    echo "PENNY: 27B HiCache ${H27} GB (rented RAM ${RAM} GB, cap min(96, RAM-100)); context ${CONTEXT}; disk free $(df -BG --output=avail "$PENNY_MODELS_ROOT" | tail -1 | tr -d ' ')"
  fi
else
  if [[ $CFG_H =~ ^[1-9][0-9]{0,3}$ ]]; then WANT=$CFG_H; else WANT=${PENNY_HICACHE_GB:-48}; fi
  [[ $WANT =~ ^[1-9][0-9]{0,3}$ && $RAM =~ ^[1-9][0-9]{0,4}$ ]] || { echo "PENNY: FATAL bad PENNY_HICACHE_GB/PENNY_RAM_GB" >&2; exit 1; }
  HICACHE_GB=$(( RAM - 100 < WANT ? RAM - 100 : WANT ))
  (( HICACHE_GB >= 8 )) || { echo "PENNY: FATAL rented RAM ${RAM} GB too small (need >=108 GB for PLE + HiCache)" >&2; exit 1; }
  export PENNY_HICACHE_GB=$HICACHE_GB
  CONTEXT=524288
  if [[ $CFG_C =~ ^(65536|131072|262144|524288)$ ]]; then CONTEXT=$CFG_C
  elif [[ -n $CFG_C ]]; then echo "PENNY: WARN bad context_length in config, using 524288"; fi
  export PENNY_CONTEXT_LENGTH=$CONTEXT
  echo "PENNY: HiCache ${HICACHE_GB} GB (rented RAM ${RAM} GB, wanted ${WANT}); context ${CONTEXT}; disk free $(df -BG --output=avail "$PENNY_MODELS_ROOT" | tail -1 | tr -d ' ')"
fi

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

# Qwen3.8-27B on one RTX 5090 (32607 MiB). Upstream is the pennyroyal-v3.0.2
# start-27b-dflash2.sh (FP8, 96 GB HiCache, context 524288, mem-fraction 0.92).
# Weights that fit: Ar4ikov AWQ 19547867688 B + DFlash2 3848817896 B.
# 8 GDN slots, 80 MiB draft KV, 512 MiB slack, static fraction 0.86
# -> 126784 fp8 KV tokens. See README.
rewrite_start_27b() {
  local file=$1 line tmp repl
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      'TARGET_MODEL='*)
        printf '%s\n' 'TARGET_MODEL="${PENNY_MODEL_DIR:?PENNY_MODEL_DIR not set}"' >> "$tmp"
        ;;
      'DRAFT_MODEL='*)
        printf '%s\n' 'DRAFT_MODEL="${PENNY_DRAFT_MODEL_DIR:?PENNY_DRAFT_MODEL_DIR not set}"' >> "$tmp"
        ;;
      'HICACHE_SIZE_GB='*)
        printf '%s\n' 'HICACHE_SIZE_GB="${PENNY_27B_HICACHE_GB:-0}"' >> "$tmp"
        ;;
      'NIXL=on')
        printf '%s\n' 'NIXL=off' >> "$tmp"
        ;;
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
      'CONTEXT_LENGTH=524288')
        printf '%s\n' 'CONTEXT_LENGTH="${PENNY_27B_CONTEXT_LENGTH:-126784}"' >> "$tmp"
        ;;
      'if [[ ! "$HICACHE_SIZE_GB" =~ ^[1-9][0-9]*$ ]]; then')
        cat >> "$tmp" <<'EOF'
# 0 disables the host pool. A ~31 GB machine cannot pin HiCache without OOM.
if [[ "$HICACHE_SIZE_GB" == 0 ]]; then
  :
elif [[ ! "$HICACHE_SIZE_GB" =~ ^[1-9][0-9]*$ ]]; then
  echo "HICACHE_SIZE_GB must be a positive integer number of GB, or 0 to disable it, got '$HICACHE_SIZE_GB'" >&2
  exit 1
fi
EOF
        IFS= read -r line || true
        IFS= read -r line || true
        IFS= read -r line || true
        ;;
      'TARGET_OVERRIDES='*)
        cat >> "$tmp" <<'EOF'
# Native context is 262144. YaRN factor 2.0 is only the stretch to 524288.
# The 5090 budget is far below that, so the usual launch injects no override.
if [[ "$CONTEXT_LENGTH" == 524288 ]]; then
  TARGET_OVERRIDES='{"text_config":{"max_position_embeddings":524288,"rope_parameters":{"mrope_interleaved":true,"mrope_section":[11,11,10],"rope_type":"yarn","rope_theta":10000000,"partial_rotary_factor":0.25,"factor":2.0,"original_max_position_embeddings":262144}}}'
  DRAFT_OVERRIDES='{"max_position_embeddings":524288,"rope_parameters":{"rope_type":"yarn","rope_theta":10000000,"factor":2.0,"original_max_position_embeddings":262144}}'
  TARGET_OVERRIDE_ARGS=(--json-model-override-args "$TARGET_OVERRIDES")
  DRAFT_OVERRIDE_ARGS=(--speculative-draft-model-override-args "$DRAFT_OVERRIDES")
else
  TARGET_OVERRIDES=''
  DRAFT_OVERRIDES=''
  TARGET_OVERRIDE_ARGS=()
  DRAFT_OVERRIDE_ARGS=()
fi
EOF
        ;;
      'DRAFT_OVERRIDES='*)
        ;;
      '  echo "NIXL disk tier: off; GPU radix cache and host-RAM HiCache only"')
        cat >> "$tmp" <<'EOF'
  if [[ "$HICACHE_SIZE_GB" == 0 ]]; then
    echo "NIXL disk tier: off; HiCache off (host RAM too small for a pinned pool)"
  else
    echo "NIXL disk tier: off; GPU radix cache and host-RAM HiCache only"
  fi
EOF
        ;;
      'launch_args=(serve \')
        cat >> "$tmp" <<'EOF'
# 5090: the KV pool is the context, not the 96 GB card's automatic size.
MAX_TOTAL_TOKENS="$CONTEXT_LENGTH"
if [[ ! "$MAX_TOTAL_TOKENS" =~ ^[0-9]+$ ]] || (( 10#$MAX_TOTAL_TOKENS <= 0 )); then
  echo "CONTEXT_LENGTH must be a positive integer" >&2; exit 1
fi
if (( 10#$MAX_TOTAL_TOKENS % PAGE_SIZE != 0 )); then
  echo "CONTEXT_LENGTH must be aligned to page size $PAGE_SIZE" >&2; exit 1
fi
TOKEN_CAP_ARGS=(--max-total-tokens "$MAX_TOTAL_TOKENS")
HICACHE_ARGS=()
if [[ "$HICACHE_SIZE_GB" != 0 ]]; then
  HICACHE_ARGS=(--enable-hierarchical-cache --hicache-size "$HICACHE_SIZE_GB" --hicache-host-memory-mode cache \
    --hicache-write-policy write_through --hicache-io-backend kernel \
    --hicache-mem-layout page_first)
fi
launch_args=(serve \
EOF
        ;;
      '  --served-model-name pennyroyal --host 0.0.0.0 --port 8001 --tp "$TP_SIZE" \')
        printf '%s\n' '  --served-model-name qwen3.8-27b --api-key "$PENNY_API_KEY" --host "${PENNY_BIND_HOST:-0.0.0.0}" --port 8001 --tp "$TP_SIZE" \' >> "$tmp"
        ;;
      '  --dtype "$COMPUTE_DTYPE" --kv-cache-dtype "$TARGET_KV_DTYPE" \')
        printf '%s\n' '  --dtype "$COMPUTE_DTYPE" --quantization "${PENNY_27B_QUANTIZATION:-compressed-tensors}" --kv-cache-dtype "$TARGET_KV_DTYPE" \' >> "$tmp"
        ;;
      '  --context-length "$CONTEXT_LENGTH" --page-size "$PAGE_SIZE" \')
        printf '%s\n' '  --context-length "$CONTEXT_LENGTH" --page-size "$PAGE_SIZE" \' >> "$tmp"
        printf '%s\n' '  "${TOKEN_CAP_ARGS[@]}" \' >> "$tmp"
        ;;
      '  --json-model-override-args "$TARGET_OVERRIDES" \')
        printf '%s\n' '  "${TARGET_OVERRIDE_ARGS[@]}" \' >> "$tmp"
        ;;
      '  --max-running-requests 4 --sleep-on-idle --mem-fraction-static 0.92 \')
        printf '%s\n' '  --max-running-requests 4 --sleep-on-idle --mem-fraction-static "${PENNY_27B_MEM_FRACTION:-0.86}" \' >> "$tmp"
        ;;
      '  --max-mamba-cache-size 24 --mamba-ssm-dtype "$MAMBA_SSM_DTYPE" \')
        printf '%s\n' '  --max-mamba-cache-size "${PENNY_27B_MAMBA_SLOTS:-8}" --mamba-ssm-dtype "$MAMBA_SSM_DTYPE" \' >> "$tmp"
        ;;
      '  --enable-hierarchical-cache --hicache-size "$HICACHE_SIZE_GB" --hicache-host-memory-mode cache \')
        printf '%s\n' '  "${HICACHE_ARGS[@]}" "${HICACHE_STORAGE_ARGS[@]}" \' >> "$tmp"
        ;;
      '  --hicache-write-policy write_through --hicache-io-backend kernel \')
        ;;
      '  --hicache-mem-layout page_first "${HICACHE_STORAGE_ARGS[@]}" \')
        ;;
      '  --speculative-draft-model-override-args "$DRAFT_OVERRIDES" \')
        printf '%s\n' '  "${DRAFT_OVERRIDE_ARGS[@]}" \' >> "$tmp"
        ;;
      *)
        if [[ $line == *'Qwen3.8-27B FP8 + DFlash2'* ]]; then line=${line/FP8/4-bit}; fi
        if [[ $line == *'max_mamba_cache_size=24'* ]]; then
          repl='max_mamba_cache_size=${PENNY_27B_MAMBA_SLOTS:-8}'
          line=${line/max_mamba_cache_size=24/$repl}
        fi
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

# 27B is a third start file. The Flash-Next sed/rewrite above is unchanged.
src27=start-27b-dflash2.sh
f=$D/upstream/$src27
if [[ ! -f $f ]]; then
  f=$C/upstream-$src27
  curl -fsSL --retry 3 "https://raw.githubusercontent.com/jpezzulli/sglang-rtxpro6000/$UP_REF/docker/pennyroyal/launch/config/$src27" -o "$f"
fi
read -r sha _ < <(sha256sum "$f")
[[ $sha == "${UP_SHA[$src27]}" ]] || { echo "PENNY: FATAL $src27 sha256 $sha != pinned $UP_REF" >&2; exit 1; }
out=$C/start-27b.sh
cp "$f" "$out"
rewrite_start_27b "$out"
# shellcheck disable=SC2016
for pat in \
  '^TARGET_MODEL="\$\{PENNY_MODEL_DIR:\?' \
  '^DRAFT_MODEL="\$\{PENNY_DRAFT_MODEL_DIR:\?' \
  '^NIXL=off$' \
  '^HICACHE_SIZE_GB="\$\{PENNY_27B_HICACHE_GB:-0\}"$' \
  '^CONTEXT_LENGTH="\$\{PENNY_27B_CONTEXT_LENGTH:-126784\}"$' \
  'served-model-name qwen3.8-27b --api-key "\$PENNY_API_KEY"' \
  '--host "\$\{PENNY_BIND_HOST:-0\.0\.0\.0\}" --port 8001' \
  ': "\$\{PENNY_REASONING_EFFORT:=xhigh\}"' \
  'if \[\[ "\$CONTEXT_LENGTH" == 524288 \]\]' \
  '--quantization "\$\{PENNY_27B_QUANTIZATION:-compressed-tensors\}"' \
  '--mem-fraction-static "\$\{PENNY_27B_MEM_FRACTION:-0\.86\}"' \
  '--max-mamba-cache-size "\$\{PENNY_27B_MAMBA_SLOTS:-8\}"' \
  '--max-total-tokens "\$MAX_TOTAL_TOKENS"' \
  '--speculative-algorithm DFLASH' \
  '--speculative-num-draft-tokens "\$DRAFT_TOKENS"' \
  '--speculative-draft-window-size "\$DRAFT_WINDOW_SIZE"' \
  '--speculative-draft-model-quantization unquant' \
  'HICACHE_ARGS=\(\)' \
  'TARGET_OVERRIDE_ARGS=\(\)' \
  'DRAFT_OVERRIDE_ARGS=\(\)' \
  '4-bit \+ DFlash2'
 do
  [[ $(grep -cE -- "$pat" "$out") == 1 ]] || { echo "PENNY: FATAL patch check failed in $out: $pat" >&2; exit 1; }
done
# The flag text lives once, inside the 524288 or non-zero arm that fills the
# array. The launch line expands the array, so a zero context and a zero
# HiCache pass nothing.
[[ $(grep -cF -- '--json-model-override-args' "$out") == 1 ]] || { echo "PENNY: FATAL 27B target YaRN flag must appear once, in the 524288 arm, in $out" >&2; exit 1; }
[[ $(grep -cF -- '--speculative-draft-model-override-args' "$out") == 1 ]] || { echo "PENNY: FATAL 27B draft YaRN flag must appear once, in the 524288 arm, in $out" >&2; exit 1; }
[[ $(grep -cF -- '--enable-hierarchical-cache' "$out") == 1 ]] || { echo "PENNY: FATAL HiCache flag must live only in the non-zero arm in $out" >&2; exit 1; }
[[ $(grep -cF -- '"${TARGET_OVERRIDE_ARGS[@]}"' "$out") == 1 ]] || { echo "PENNY: FATAL 27B launch must expand TARGET_OVERRIDE_ARGS once in $out" >&2; exit 1; }
[[ $(grep -cF -- '"${DRAFT_OVERRIDE_ARGS[@]}"' "$out") == 1 ]] || { echo "PENNY: FATAL 27B launch must expand DRAFT_OVERRIDE_ARGS once in $out" >&2; exit 1; }
[[ $(grep -cF -- '"${HICACHE_ARGS[@]}"' "$out") == 1 ]] || { echo "PENNY: FATAL 27B launch must expand HICACHE_ARGS once in $out" >&2; exit 1; }
[[ $(grep -cF 'rope_type":"yarn"' "$out") == 2 ]] || { echo "PENNY: FATAL 27B YaRN must appear twice, only in the 524288 arm, in $out" >&2; exit 1; }
bash -n "$out"
echo "PENNY: start file ready (27b)"

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
