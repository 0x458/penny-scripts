#!/usr/bin/env bash
# Penny v5 boot (Penny Royal v3.0.2 + jpezzulli Orca NVFP4 @f24d2b68 on one RTX PRO 6000).
# Prepares both start files (plain = default, frspec) from the pinned upstream copies, optional Tailscale,
# then runs ctl.py (:8002), which downloads the pinned model, writes .complete and starts SGLang (:8001).
# Env: PENNY_API_KEY (required), PENNY_RAM_GB (rented RAM from the offer, caps HiCache), optional
#      PENNY_HICACHE_GB, PENNY_MODE (plain|frspec), PENNY_MODEL (must be in models.allow), TS_AUTHKEY, TS_TAGS.
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
# PENNY_RAM_GB. Budget: RAM PLE ~51 GB + process/pinned buffers ~40 GB => HiCache <= RAM - 100, max 48.
WANT=${PENNY_HICACHE_GB:-48}
RAM=${PENNY_RAM_GB:-}
if [[ -z $RAM ]]; then
  RAM=$(awk '/MemTotal/{printf "%d", $2/1e6}' /proc/meminfo)
  echo "PENNY: WARN PENNY_RAM_GB unset; using MemTotal ${RAM} GB (may be the host's, not the rental)"
fi
[[ $WANT =~ ^[1-9][0-9]{0,3}$ && $RAM =~ ^[1-9][0-9]{0,4}$ ]] || { echo "PENNY: FATAL bad PENNY_HICACHE_GB/PENNY_RAM_GB" >&2; exit 1; }
HICACHE_GB=$(( RAM - 100 < WANT ? RAM - 100 : WANT ))
(( HICACHE_GB >= 8 )) || { echo "PENNY: FATAL rented RAM ${RAM} GB too small (need >=108 GB for PLE + HiCache)" >&2; exit 1; }
echo "PENNY: HiCache ${HICACHE_GB} GB (rented RAM ${RAM} GB, wanted ${WANT}); disk free $(df -BG --output=avail "$PENNY_MODELS_ROOT" | tail -1 | tr -d ' ')"

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
      -e "s|^HICACHE_SIZE_GB=.*|HICACHE_SIZE_GB=$HICACHE_GB|" \
      -e 's|--served-model-name pennyroyal \\|--served-model-name flash-next --api-key "$PENNY_API_KEY" \\|' "$f" > "$out"
  # Every patch must land exactly once.
  # shellcheck disable=SC2016
  for pat in '^TARGET_MODEL="\$\{PENNY_MODEL_DIR:\?' '^NIXL=off$' "^HICACHE_SIZE_GB=$HICACHE_GB\$" 'served-model-name flash-next --api-key "\$PENNY_API_KEY"'; do
    [[ $(grep -cE -- "$pat" "$out") == 1 ]] || { echo "PENNY: FATAL patch check failed in $out: $pat" >&2; exit 1; }
  done
  bash -n "$out"
done
echo "PENNY: start files ready (frspec, plain)"

# Optional Tailscale (userspace; image has no root/TUN). Only with TS_AUTHKEY; key passed via a 0600 file, not argv.
if [[ -n ${TS_AUTHKEY:-} ]]; then
  TS=$C/ts; mkdir -p "$TS/state"
  (
    set -e
    if [[ ! -x $TS/tailscaled ]]; then
      V=$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json' | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["TarballsVersion"])')
      curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${V}_amd64.tgz" -o "$TS/ts.tgz"
      "$PY" -c 'import sys,tarfile,os,shutil
t=tarfile.open(sys.argv[1])
for m in t.getmembers():
    b=os.path.basename(m.name)
    if b in ("tailscale","tailscaled") and m.isfile():
        with t.extractfile(m) as s, open(os.path.join(sys.argv[2],b),"wb") as o: shutil.copyfileobj(s,o)
        os.chmod(os.path.join(sys.argv[2],b),0o755)' "$TS/ts.tgz" "$TS"
    fi
    nohup "$TS/tailscaled" --tun=userspace-networking --statedir="$TS/state" --socket="$TS/sock" > "$C/logs/tailscaled.log" 2>&1 &
    sleep 3
    umask 077; printf '%s' "$TS_AUTHKEY" > "$TS/authkey"
    "$TS/tailscale" --socket="$TS/sock" up --hostname="${TS_HOSTNAME:-vast-penny}" --auth-key="file:$TS/authkey" ${TS_TAGS:+--advertise-tags="$TS_TAGS"}
    rm -f "$TS/authkey"
    "$TS/tailscale" --socket="$TS/sock" serve --bg --tcp 8000 tcp://127.0.0.1:8001
    echo "PENNY: tailscale up + serve tcp 8000 ok"
  ) || echo "PENNY: WARN tailscale failed (public ports 8001/8002 still work)"
  rm -f "$TS/authkey"
else
  echo "PENNY: TS_AUTHKEY unset, skipping tailscale"
fi
unset TS_AUTHKEY
exec "$PY" "$D/ctl.py"
