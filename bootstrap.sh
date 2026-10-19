#!/usr/bin/env bash
# Penny v5 bootstrap: fetch the scripts repo, then hand over to boot.sh.
# Vast args (Entrypoint mode; the image entrypoint only accepts commands that start with exec):
#   exec bash -c 'echo "$PENNY_BOOTSTRAP_B64" | base64 -d > /cache/bootstrap.sh && exec bash /cache/bootstrap.sh'
# Env: PENNY_REPO_URL (https), PENNY_REPO_REF (tag/branch/40-hex sha; pin a sha in production),
#      GH_TOKEN (optional, read-only fine-grained PAT for a private repo; never logged, unset before boot.sh).
# Fallback order: fresh fetch -> cached copy from an earlier boot in /cache -> PENNY_BOOT_B64 + PENNY_CTL_B64 -> exit 1.
set -uo pipefail
C=${PENNY_CACHE:-/cache}
export HOME=$C
REPO_URL=${PENNY_REPO_URL:?set PENNY_REPO_URL (https URL of the private scripts repo)}
REF=${PENNY_REPO_REF:-main}
SUB=${PENNY_REPO_SUBDIR:-.}
D=$C/penny-vast
NEW=$C/penny-vast.new
mkdir -p "$C/logs"
log() { echo "PENNY-BOOTSTRAP: $* ($(date -u +%FT%TZ))" | tee -a "$C/logs/bootstrap.log"; }

case $REPO_URL in https://*) ;; *) log "PENNY_REPO_URL must be https"; exit 1 ;; esac
if [[ ! $REF =~ ^[A-Za-z0-9._/-]{1,100}$ || $REF == *..* || ! $SUB =~ ^[A-Za-z0-9._/-]{1,100}$ || $SUB == *..* ]]; then
  log "bad PENNY_REPO_REF or PENNY_REPO_SUBDIR"; exit 1
fi

fetch() {
  rm -rf "$NEW"
  local -a cfg=()
  if [[ -n ${GH_TOKEN:-} ]]; then
    # Token goes in through GIT_CONFIG_* env (not argv, not the URL, not .git/config).
    cfg=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader
         "GIT_CONFIG_VALUE_0=Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)")
  fi
  git init -q "$NEW" || return 1
  git -C "$NEW" remote add origin "$REPO_URL" || return 1
  env GIT_TERMINAL_PROMPT=0 "${cfg[@]}" timeout 120 git -C "$NEW" -c credential.helper= fetch -q --depth 1 origin "$REF" || return 1
  git -C "$NEW" checkout -q --detach FETCH_HEAD || return 1
  local head; head=$(git -C "$NEW" rev-parse HEAD)
  if [[ $REF =~ ^[0-9a-f]{40}$ && $head != "$REF" ]]; then log "HEAD $head != pinned $REF"; return 1; fi
  [[ -f $NEW/$SUB/boot.sh && -f $NEW/$SUB/ctl.py ]] || { log "boot.sh/ctl.py missing in $SUB"; return 1; }
  echo "$head" > "$NEW/.penny-head"
}

for i in 1 2 3; do
  if fetch; then rm -rf "$D" && mv "$NEW" "$D" && log "fetched $REPO_URL@$REF -> $(cat "$D/.penny-head")"; SRC=$D/$SUB; break; fi
  log "fetch attempt $i failed"; sleep $((i * 5))
done
if [[ -z ${SRC:-} && -f $D/$SUB/boot.sh && -f $D/$SUB/ctl.py ]]; then
  SRC=$D/$SUB; log "WARN: using cached copy $(cat "$D/.penny-head" 2>/dev/null)"
fi
if [[ -z ${SRC:-} && -n ${PENNY_BOOT_B64:-} && -n ${PENNY_CTL_B64:-} ]]; then
  SRC=$C/penny-embedded; mkdir -p "$SRC"
  echo "$PENNY_BOOT_B64" | base64 -d > "$SRC/boot.sh" && echo "$PENNY_CTL_B64" | base64 -d > "$SRC/ctl.py" || exit 1
  log "WARN: using embedded PENNY_BOOT_B64/PENNY_CTL_B64 (upstream start files come from GitHub raw)"
fi
[[ -n ${SRC:-} ]] || { log "FATAL: no scripts (fetch failed, no cache, no embedded copy)"; exit 1; }
rm -rf "$NEW"
exec env -u GH_TOKEN -u PENNY_BOOTSTRAP_B64 -u PENNY_BOOT_B64 -u PENNY_CTL_B64 bash "$SRC/boot.sh"
