#!/usr/bin/env bash
# shellcheck disable=SC2015
# Tailscale block of boot.sh with stub tailscale/tailscaled. Usage: bash test/ts_test.sh <boot.sh>
# Expect: "tailscale up + serve tcp 8000 ok" only when up succeeds AND BackendState=Running AND serve succeeds;
# otherwise a WARN, and boot continues to exec ctl.py (here PENNY_PY=true stands in for it).
set -uo pipefail
BOOT=$(readlink -f "${1:?boot.sh}"); T=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PASS=0; FAIL=0
for mode in ok up_fail not_running serve_fail dl_fail; do
  W=$(mktemp -d /tmp/pv5ts.XXXX); C=$W/cache; mkdir -p "$C/ts"
  proxy=""
  if [[ $mode == dl_fail ]]; then proxy=http://127.0.0.1:9   # no binaries + unreachable proxy -> download fails
  else cp "$T/fake_tailscale.sh" "$C/ts/tailscale"; cp "$T/fake_tailscaled.sh" "$C/ts/tailscaled"; chmod +x "$C/ts/"*; fi
  https_proxy=$proxy HTTPS_PROXY=$proxy PENNY_CACHE=$C PENNY_API_KEY=k PENNY_RAM_GB=189 PENNY_PY=true TS_AUTHKEY=tskey-fake FAKE_TS_MODE=$mode FAKE_TS_LOG=$W/ts.log \
    PENNY_TS_POLL=3 timeout 60 bash "$BOOT" > "$W/out.log" 2>&1; rc=$?
  okline=$(grep -c "tailscale up + serve tcp 8000 ok" "$W/out.log"); warn=$(grep -c "WARN tailscale" "$W/out.log")
  echo "[$mode] rc=$rc ok_lines=$okline warn_lines=$warn :: $(grep -E 'tailscale|BackendState' "$W/out.log" | tr '\n' '|' | cut -c1-220)"
  if [[ $mode == ok ]]; then want_ok=1; want_warn=0; else want_ok=0; want_warn=1; fi
  if [[ $okline == "$want_ok" && $warn == "$want_warn" && $rc == 0 ]]; then echo "PASS ts $mode"; PASS=$((PASS+1)); else echo "FAIL ts $mode"; FAIL=$((FAIL+1)); fi
  grep -q "tskey-fake" "$W/out.log" "$W/ts.log" && { echo "FAIL ts $mode: authkey leaked"; FAIL=$((FAIL+1)); } || { echo "PASS ts $mode: authkey not in logs/argv"; PASS=$((PASS+1)); }
  [[ ! -e $C/ts/authkey ]] && { echo "PASS ts $mode: authkey file removed"; PASS=$((PASS+1)); } || { echo "FAIL ts $mode: authkey file left"; FAIL=$((FAIL+1)); }
  pkill -f "$C/ts/sock" 2>/dev/null
done
echo "=== TS RESULT: $PASS passed, $FAIL failed"
