#!/usr/bin/env bash
# shellcheck disable=SC2015
# Tailscale block of boot.sh with stub tailscale/tailscaled. Usage: bash test/ts_test.sh <boot.sh>
# Expect: "tailscale up + serve tcp 8000 ok" only when up succeeds AND BackendState=Running AND serve succeeds;
# otherwise a WARN, and boot continues to exec ctl.py (here PENNY_PY=true stands in for it).
# ok also binds 127.0.0.1 and serves tcp/8002. public_bind (PENNY_PUBLIC_BIND=1) keeps 0.0.0.0.
# TS_TAGS defaults to empty: tailscale up must not receive --advertise-tags. A non-empty TS_TAGS passes it.
set -uo pipefail
unset TS_AUTHKEY TS_TAGS GH_TOKEN
BOOT=$(readlink -f "${1:?boot.sh}"); T=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PASS=0; FAIL=0
for mode in ok up_fail not_running serve_fail dl_fail public_bind; do
  W=$(mktemp -d /tmp/pv5ts.XXXX); C=$W/cache; mkdir -p "$C/ts"
  proxy=""; ts_mode=$mode; pub=""
  if [[ $mode == public_bind ]]; then ts_mode=ok; pub=1; fi
  if [[ $mode == dl_fail ]]; then proxy=http://127.0.0.1:9   # no binaries + unreachable proxy -> download fails
  else cp "$T/fake_tailscale.sh" "$C/ts/tailscale"; cp "$T/fake_tailscaled.sh" "$C/ts/tailscaled"; chmod +x "$C/ts/"*; fi
  https_proxy=$proxy HTTPS_PROXY=$proxy PENNY_CACHE=$C PENNY_API_KEY=k PENNY_RAM_GB=189 PENNY_PY=true TS_AUTHKEY=tskey-fake FAKE_TS_MODE=$ts_mode FAKE_TS_LOG=$W/ts.log \
    PENNY_PUBLIC_BIND=$pub PENNY_TS_POLL=3 timeout 60 bash "$BOOT" > "$W/out.log" 2>&1; rc=$?
  okline=$(grep -c "tailscale up + serve tcp 8000 ok" "$W/out.log"); warn=$(grep -c "WARN tailscale" "$W/out.log")
  echo "[$mode] rc=$rc ok_lines=$okline warn_lines=$warn :: $(grep -E 'tailscale|BackendState|bind' "$W/out.log" | tr '\n' '|' | cut -c1-220)"
  if [[ $mode == ok || $mode == public_bind ]]; then want_ok=1; want_warn=0; else want_ok=0; want_warn=1; fi
  if [[ $okline == "$want_ok" && $warn == "$want_warn" && $rc == 0 ]]; then echo "PASS ts $mode"; PASS=$((PASS+1)); else echo "FAIL ts $mode"; FAIL=$((FAIL+1)); fi
  if [[ $mode == ok ]]; then
    if grep -q "bind 127.0.0.1" "$W/out.log" && grep -q "serve --bg --tcp 8000 tcp://127.0.0.1:8001" "$W/ts.log" && grep -q "serve --bg --tcp 8002 tcp://127.0.0.1:8002" "$W/ts.log"; then
      echo "PASS ts $mode: bind 127.0.0.1 and serve 8000+8002"; PASS=$((PASS+1))
    else echo "FAIL ts $mode: bind/serve"; FAIL=$((FAIL+1)); fi
  elif [[ $mode == public_bind ]]; then
    if grep -q "PENNY_PUBLIC_BIND=1" "$W/out.log" && ! grep -q "bind 127.0.0.1" "$W/out.log"; then
      echo "PASS ts $mode: stays on 0.0.0.0"; PASS=$((PASS+1))
    else echo "FAIL ts $mode: public bind"; FAIL=$((FAIL+1)); fi
  else
    if ! grep -q "bind 127.0.0.1" "$W/out.log"; then echo "PASS ts $mode: not tailnet-bound"; PASS=$((PASS+1))
    else echo "FAIL ts $mode: bound 127.0.0.1 after failure"; FAIL=$((FAIL+1)); fi
    if grep -q 'vastai logs' "$W/out.log" && grep -q 'TAILNET=1' "$W/out.log" && grep -q 'vastai reboot instance' "$W/out.log" && grep -q 'binding 0.0.0.0' "$W/out.log"; then
      echo "PASS ts $mode: fallback WARN tells you vastai logs and reboot"; PASS=$((PASS+1))
    else echo "FAIL ts $mode: fallback WARN"; FAIL=$((FAIL+1)); fi
  fi
  grep -q "tskey-fake" "$W/out.log" "$W/ts.log" && { echo "FAIL ts $mode: authkey leaked"; FAIL=$((FAIL+1)); } || { echo "PASS ts $mode: authkey not in logs/argv"; PASS=$((PASS+1)); }
  [[ ! -e $C/ts/authkey ]] && { echo "PASS ts $mode: authkey file removed"; PASS=$((PASS+1)); } || { echo "FAIL ts $mode: authkey file left"; FAIL=$((FAIL+1)); }
  if [[ -f $W/ts.log ]] && grep -q ' up ' "$W/ts.log"; then
    if grep -q -- '--advertise-tags' "$W/ts.log"; then echo "FAIL ts $mode: --advertise-tags with empty TS_TAGS"; FAIL=$((FAIL+1))
    else echo "PASS ts $mode: no --advertise-tags"; PASS=$((PASS+1)); fi
  fi
  pkill -f "$C/ts/sock" 2>/dev/null
done
# Explicit empty TS_TAGS (what `-e TS_TAGS=` puts in the container) and a non-empty value.
for tags_case in empty set; do
  W=$(mktemp -d /tmp/pv5ts.XXXX); C=$W/cache; mkdir -p "$C/ts"
  cp "$T/fake_tailscale.sh" "$C/ts/tailscale"; cp "$T/fake_tailscaled.sh" "$C/ts/tailscaled"; chmod +x "$C/ts/"*
  tagval=""; [[ $tags_case == set ]] && tagval="tag:penny"
  PENNY_CACHE=$C PENNY_API_KEY=k PENNY_RAM_GB=189 PENNY_PY=true TS_AUTHKEY=tskey-fake TS_TAGS="$tagval" FAKE_TS_MODE=ok FAKE_TS_LOG=$W/ts.log \
    PENNY_TS_POLL=3 timeout 60 bash "$BOOT" > "$W/out.log" 2>&1; rc=$?
  okline=$(grep -c "tailscale up + serve tcp 8000 ok" "$W/out.log")
  echo "[tags_$tags_case] rc=$rc ok_lines=$okline :: $(grep ' up ' "$W/ts.log" | tr '\n' '|' | cut -c1-180)"
  if [[ $tags_case == empty ]]; then
    if [[ $rc == 0 && $okline == 1 ]] && ! grep -q -- '--advertise-tags' "$W/ts.log"; then echo "PASS ts tags_empty"; PASS=$((PASS+1)); else echo "FAIL ts tags_empty"; FAIL=$((FAIL+1)); fi
  else
    if [[ $rc == 0 && $okline == 1 ]] && grep -q -- '--advertise-tags=tag:penny' "$W/ts.log"; then echo "PASS ts tags_set"; PASS=$((PASS+1)); else echo "FAIL ts tags_set"; FAIL=$((FAIL+1)); fi
  fi
  grep -q "tskey-fake" "$W/out.log" "$W/ts.log" && { echo "FAIL ts tags_$tags_case: authkey leaked"; FAIL=$((FAIL+1)); } || { echo "PASS ts tags_$tags_case: authkey not in logs"; PASS=$((PASS+1)); }
  pkill -f "$C/ts/sock" 2>/dev/null
done
echo "=== TS RESULT: $PASS passed, $FAIL failed"
