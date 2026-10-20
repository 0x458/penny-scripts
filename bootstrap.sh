#!/usr/bin/env bash
# Penny v5 bootstrap: fetch the scripts repo, then hand over to boot.sh.
# Vast args (Entrypoint mode; the image entrypoint only accepts commands that start with exec):
#   exec bash -c 'echo "$PENNY_BOOTSTRAP_B64" | base64 -d > /cache/bootstrap.sh && exec bash /cache/bootstrap.sh'
# Env: PENNY_REPO_URL (https), PENNY_REPO_REF (required on first boot: a release tag such as v5.2; a 40-hex sha or
#      branch also works). GH_TOKEN (optional, read-only PAT for a private repo; never logged, unset before boot.sh).
# /cache/penny-ref, when it holds a release tag, overrides PENNY_REPO_REF (POST /upgrade, then vastai reboot).
# /cache/penny-ref-good is the last ref whose SGLang passed /health. A fetched ref that dies or never becomes
# healthy is rolled back to that ref and /cache/penny-vast-good. The model directory is not touched.
# Fallback order: fresh fetch -> cached copy from an earlier boot in /cache -> PENNY_BOOT_B64 + PENNY_CTL_B64 -> exit 1.
set -uo pipefail
C=${PENNY_CACHE:-/cache}
export HOME=$C
REPO_URL=${PENNY_REPO_URL:?set PENNY_REPO_URL (https URL of the private scripts repo)}
REF=${PENNY_REPO_REF:?set PENNY_REPO_REF to a release tag, e.g. v5.2}
SUB=${PENNY_REPO_SUBDIR:-.}
D=$C/penny-vast
NEW=$C/penny-vast.new
mkdir -p "$C/logs"
log() { echo "PENNY-BOOTSTRAP: $* ($(date -u +%FT%TZ))" | tee -a "$C/logs/bootstrap.log"; }
atomic_line() {
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || return 1
  printf '%s\n' "$2" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$1"
}
kill_tree() {
  local pid=$1 c
  [[ -n ${pid:-} ]] || return 0
  for c in $(ps -o pid= --ppid "$pid" 2>/dev/null); do kill_tree "$c"; done
  kill -TERM "$pid" 2>/dev/null || true
}
# pennyroyal-v3.0.2 auth.py allows every path starting with /health even when --api-key is set, so this
# request carries no key. curl -f treats 401 as failure. The key must not appear in argv or this log.
sglang_healthy() { curl -fsS -m 2 "http://127.0.0.1:${PENNY_SGLANG_PORT:-8001}/health" >/dev/null 2>&1; }
# Replace dest with dest.new without deleting dest first. A failed second mv puts dest.old back.
swap_in() {
  local dest=$1
  rm -rf "$dest.old"
  if [[ -e $dest ]]; then mv "$dest" "$dest.old"; fi
  if mv "$dest.new" "$dest"; then rm -rf "$dest.old"; return 0; fi
  [[ -e $dest.old ]] && mv "$dest.old" "$dest"
  return 1
}
mark_good() { # $1 = directory that contains boot.sh; its .penny-ref is the only ref this records
  local ref dest=$C/penny-vast-good
  [[ -f $1/.penny-ref ]] || { log "WARN no .penny-ref in scripts; not recording penny-ref-good"; return 0; }
  ref=$(head -n 1 "$1/.penny-ref" | tr -d '[:space:]')
  [[ -n $ref ]] || return 0
  rm -rf "$dest.new"
  mkdir -p "$dest.new"
  cp -a "$1/." "$dest.new/"
  swap_in "$dest" || return 1
  atomic_line "$C/penny-ref-good" "$ref" || return 1
  log "recorded good ref $ref"
}
if [[ -f $C/penny-ref ]]; then
  FILE_REF=$(head -n 1 "$C/penny-ref" | tr -d '[:space:]')
  if [[ $FILE_REF =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    log "recorded ref $FILE_REF overrides env PENNY_REPO_REF=$REF"
    REF=$FILE_REF
  else
    log "WARN ignoring bad penny-ref"
  fi
fi

case $REPO_URL in https://*) ;; *) log "PENNY_REPO_URL must be https"; exit 1 ;; esac
if [[ ! $REF =~ ^[A-Za-z0-9._/-]{1,100}$ || $REF == *..* || ! $SUB =~ ^[A-Za-z0-9._/-]{1,100}$ || $SUB == *..* ]]; then
  log "bad PENNY_REPO_REF or PENNY_REPO_SUBDIR"; exit 1
fi

fetch() {
  rm -rf "$NEW"
  git init -q "$NEW" || return 1
  git -C "$NEW" remote add origin "$REPO_URL" || return 1
  (
    # Token: exported by bash builtins inside this subshell, so it is in git's environment only - not in any
    # process argv (/proc/*/cmdline), not in the URL, not in .git/config, not in logs. printf is a builtin too.
    export GIT_TERMINAL_PROMPT=0
    if [[ -n ${GH_TOKEN:-} ]]; then
      GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
      export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0
    fi
    if [[ $REF =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
      hit=$(timeout 30 git -C "$NEW" -c credential.helper= ls-remote --tags origin "refs/tags/$REF") || { log "tag $REF lookup failed"; exit 1; }
      ok=0
      while IFS=$'\t' read -r _ name; do [[ $name == "refs/tags/$REF" ]] && ok=1; done <<< "$hit"
      [[ $ok == 1 ]] || { log "tag $REF not found on origin"; exit 1; }
    fi
    timeout 120 git -C "$NEW" -c credential.helper= fetch -q --depth 1 origin "$REF"
  ) || return 1
  git -C "$NEW" checkout -q --detach FETCH_HEAD || return 1
  local head; head=$(git -C "$NEW" rev-parse HEAD)
  if [[ $REF =~ ^[0-9a-f]{40}$ && $head != "$REF" ]]; then log "HEAD $head != pinned $REF"; return 1; fi
  [[ -f $NEW/$SUB/boot.sh && -f $NEW/$SUB/ctl.py ]] || { log "boot.sh/ctl.py missing in $SUB"; return 1; }
  echo "$head" > "$NEW/.penny-head"
}

FETCHED=0
for i in 1 2 3; do
  if fetch && rm -rf "$D" && mv "$NEW" "$D" && atomic_line "$C/penny-ref" "$REF"; then
    log "fetched $REPO_URL@$REF -> $(cat "$D/.penny-head")"
    SRC=$D/$SUB
    # The installed tree's own ref. Cache/embedded fallback must not inherit /cache/penny-ref.
    atomic_line "$SRC/.penny-ref" "$REF" || log "WARN could not write .penny-ref"
    FETCHED=1
    break
  fi
  log "fetch attempt $i failed"; sleep $((i * 5))
done
if [[ -z ${SRC:-} && -f $D/$SUB/boot.sh && -f $D/$SUB/ctl.py ]]; then
  SRC=$D/$SUB; log "WARN: using cached copy $(cat "$D/.penny-head" 2>/dev/null)"
fi
if [[ -z ${SRC:-} && -n ${PENNY_BOOT_B64:-} && -n ${PENNY_CTL_B64:-} ]]; then
  SRC=$C/penny-embedded; mkdir -p "$SRC"
  echo "$PENNY_BOOT_B64" | base64 -d > "$SRC/boot.sh" && echo "$PENNY_CTL_B64" | base64 -d > "$SRC/ctl.py" || exit 1
  atomic_line "$SRC/.penny-ref" "embedded" || log "WARN could not write .penny-ref"
  log "WARN: using embedded PENNY_BOOT_B64/PENNY_CTL_B64 (upstream start files come from GitHub raw)"
fi
[[ -n ${SRC:-} ]] || { log "FATAL: no scripts (fetch failed, no cache, no embedded copy)"; exit 1; }
rm -rf "$NEW"
good_ref=""
[[ -f $C/penny-ref-good ]] && good_ref=$(head -n 1 "$C/penny-ref-good" | tr -d '[:space:]')
# A new ref is supervised here, not inside the fetched boot.sh: that file may be the one that fails.
if [[ $FETCHED == 1 && -n $good_ref && $good_ref != "$REF" && -f $C/penny-vast-good/boot.sh ]]; then
  log "trying ref $REF (last good ref is $good_ref)"
  env -u GH_TOKEN -u PENNY_BOOTSTRAP_B64 -u PENNY_BOOT_B64 -u PENNY_CTL_B64 PENNY_SUPERVISED=1 bash "$SRC/boot.sh" &
  pid=$!
  ok=0
  tout=${PENNY_HEALTH_TIMEOUT:-1800}
  for ((i = 0; i < tout; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    if sglang_healthy && kill -0 "$pid" 2>/dev/null; then ok=1; break; fi
    sleep 1
  done
  if [[ $ok == 1 ]]; then
    mark_good "$SRC"
    wait "$pid"
    exit $?
  fi
  log "WARN ref $REF failed SGLang start or health check; rolled back to $good_ref. Model and /cache stay; no recycle. Read vastai logs <id> and /cache/logs/bootstrap.log"
  kill_tree "$pid"
  sleep 1
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$D"
  mkdir -p "$D"
  cp -a "$C/penny-vast-good/." "$D/" || { log "FATAL: could not restore $good_ref"; exit 1; }
  atomic_line "$C/penny-ref" "$good_ref" || { log "FATAL: could not restore penny-ref"; exit 1; }
  exec env -u GH_TOKEN -u PENNY_BOOTSTRAP_B64 -u PENNY_BOOT_B64 -u PENNY_CTL_B64 PENNY_ROLLED_BACK=1 bash "$D/$SUB/boot.sh"
fi
exec env -u GH_TOKEN -u PENNY_BOOTSTRAP_B64 -u PENNY_BOOT_B64 -u PENNY_CTL_B64 bash "$SRC/boot.sh"
