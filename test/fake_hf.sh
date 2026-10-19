#!/usr/bin/env bash
# Stub for `hf download REPO --revision REV --local-dir DIR ...`: copies $FAKE_HF_DATA/<repo name>/ into DIR.
echo "fake_hf argv: $*" >> "$FAKE_HF_LOG"
[[ $1 == download ]] || exit 2
repo=$2; dir=""; rev=""
shift 2
while [[ $# -gt 0 ]]; do case $1 in --local-dir) dir=$2; shift 2 ;; --revision) rev=$2; shift 2 ;; *) shift ;; esac; done
[[ -n $dir && $rev =~ ^[0-9a-f]{40}$ ]] || exit 3
sleep 1
# Flaky once: if $FAKE_HF_FLAKY_DIR/<name> exists, remove it and deliver only config.json (rc 0, incomplete).
if [[ -n ${FAKE_HF_FLAKY_DIR:-} && -e $FAKE_HF_FLAKY_DIR/${repo#*/} ]]; then
  rm -f "$FAKE_HF_FLAKY_DIR/${repo#*/}"; cp "$FAKE_HF_DATA/${repo#*/}/config.json" "$dir/"; exit 0
fi
cp -r "$FAKE_HF_DATA/${repo#*/}/." "$dir/"
