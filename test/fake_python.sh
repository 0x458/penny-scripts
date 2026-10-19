#!/usr/bin/env bash
# Stub for the image venv python used by the upstream start file's probes (torch device count, identity probe).
code=${2:-}
case $code in
  *range\(torch.cuda.device_count*) echo 0 ;;
  *torch.cuda.device_count*) echo 1 ;;
  *launch_precision*) printf '2.11.0+cu133\nfalse\n' ;;
  *) echo "fake_python: unhandled: ${code:0:80}" >&2 ;;
esac
