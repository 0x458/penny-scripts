#!/usr/bin/env bash
# Stub for tailscale CLI. FAKE_TS_MODE: ok | up_fail | not_running | serve_fail | renamed
# `renamed` is a hostname collision: Self is "<hostname>-1" with a tailnet IP.
echo "fake_tailscale $*" >> "${FAKE_TS_LOG:-/dev/null}"
state=${FAKE_TS_STATE:-${FAKE_TS_LOG:-/tmp/fake-ts}.host}
args=" $* "
host=vast-penny
[[ -f $state ]] && host=$(cat "$state")
for a in "$@"; do case $a in --hostname=*) host=${a#--hostname=} ;; esac; done
case $args in
  *" up "*)
    [[ $FAKE_TS_MODE == up_fail ]] && { echo "backend error: invalid key" >&2; exit 1; }
    printf '%s' "$host" > "$state"
    exit 0 ;;
  *" status "*)
    if [[ $FAKE_TS_MODE == not_running ]]; then echo '{"BackendState": "NeedsLogin"}'
    elif [[ $FAKE_TS_MODE == renamed ]]; then
      printf '%s\n' "{\"Version\": \"1.90\", \"BackendState\": \"Running\", \"Self\": {\"HostName\": \"${host}-1\", \"DNSName\": \"${host}-1.tailnet.ts.net.\", \"TailscaleIPs\": [\"100.64.1.2\"]}}"
    else
      printf '%s\n' "{\"Version\": \"1.90\", \"BackendState\": \"Running\", \"Self\": {\"HostName\": \"${host}\", \"DNSName\": \"${host}.tailnet.ts.net.\", \"TailscaleIPs\": [\"100.64.1.1\"]}}"
    fi
    exit 0 ;;
  *" serve "*) [[ $FAKE_TS_MODE == serve_fail ]] && exit 1; exit 0 ;;
esac
exit 0
