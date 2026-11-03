#!/bin/bash
# Resolve the latest AOSP clang (version + tag). Prints two KEY=VALUE lines to stdout; logs go to stderr.
# Any failure falls back to the pinned, known-good version.
PIN_VER="r596125"
PIN_TAG="android-17.0.0_r1"
BASE="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"

# Gitiles responses can be plain or base64 depending on the endpoint: emit raw + decoded output, then grep.
fetch_text() {
  local raw
  raw=$(curl -fsS --max-time 30 --retry 2 --retry-delay 5 "$1" 2>/dev/null) || return 1
  printf '%s\n' "$raw"
  printf '%s' "$raw" | base64 -d 2>/dev/null
  return 0
}

TAG=""; VER=""
tags=$(fetch_text "$BASE/+refs/tags?format=TEXT" | grep -oE 'android-[0-9]+(\.[0-9]+)*_r[0-9]+' | sort -uV)
if [ -n "$tags" ]; then
  # newest tag first; take the first one whose tree contains clang-rNNNNNN, highest version wins
  for t in $(printf '%s\n' "$tags" | tac | head -6); do
    v=$(fetch_text "$BASE/+/refs/tags/$t/?format=TEXT" | grep -oE 'clang-r[0-9]+' | sort -uV | tail -1)
    if [ -n "$v" ]; then TAG="$t"; VER="${v#clang-}"; break; fi
  done
fi

if [ -z "$VER" ]; then
  echo "[!] failed to resolve latest AOSP clang, falling back to pinned ${PIN_VER} (${PIN_TAG})" >&2
  TAG="$PIN_TAG"; VER="$PIN_VER"
else
  echo "[+] latest AOSP clang: ${VER} (tag: ${TAG})" >&2
fi
echo "AOSP_CLANG_VER=${VER}"
echo "AOSP_CLANG_TAG=${TAG}"
