#!/usr/bin/env bash
# Stub for tailscaled: creates the --socket unix socket and idles for a while.
for a in "$@"; do case $a in --socket=*) s=${a#--socket=} ;; esac; done
exec python3 -c 'import socket,sys,time; x=socket.socket(socket.AF_UNIX); x.bind(sys.argv[1]); x.listen(1); time.sleep(60)' "$s"
