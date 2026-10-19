#!/usr/bin/env bash
# Stub for tailscale CLI. FAKE_TS_MODE: ok | up_fail | not_running | serve_fail
echo "fake_tailscale $*" >> "${FAKE_TS_LOG:-/dev/null}"
args=" $* "
case $args in
  *" up "*) [[ $FAKE_TS_MODE == up_fail ]] && { echo "backend error: invalid key" >&2; exit 1; }; exit 0 ;;
  *" status "*) if [[ $FAKE_TS_MODE == not_running ]]; then echo '{"BackendState": "NeedsLogin"}'; else echo '{"Version": "1.90", "BackendState": "Running"}'; fi; exit 0 ;;
  *" serve "*) [[ $FAKE_TS_MODE == serve_fail ]] && exit 1; exit 0 ;;
esac
exit 0
