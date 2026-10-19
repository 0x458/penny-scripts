#!/usr/bin/env bash
# Stub for `hf download REPO --revision REV --local-dir DIR ...`: copies $FAKE_HF_DATA/<repo name>/ into DIR.
echo "fake_hf argv: $*" >> "$FAKE_HF_LOG"
[[ $1 == download ]] || exit 2
repo=$2; dir=""; rev=""
shift 2
while [[ $# -gt 0 ]]; do case $1 in --local-dir) dir=$2; shift 2 ;; --revision) rev=$2; shift 2 ;; *) shift ;; esac; done
[[ -n $dir && $rev =~ ^[0-9a-f]{40}$ ]] || exit 3
sleep 1
cp -r "$FAKE_HF_DATA/${repo#*/}/." "$dir/"
