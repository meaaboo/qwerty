#!/bin/bash
# Retry helpers for flaky network git ops (gitlab/github sideband disconnects etc).
# Defined as functions only; sourced first in build.sh LIB_ORDER.
#   GIT_RETRY_ATTEMPTS  (default 4)   GIT_RETRY_TIMEOUT (default 180s per attempt)

GIT_RETRY_ATTEMPTS="${GIT_RETRY_ATTEMPTS:-4}"
GIT_RETRY_TIMEOUT="${GIT_RETRY_TIMEOUT:-180}"

# git_retry <git args...> — run `git ...` with per-attempt timeout, stall abort and backoff.
git_retry() {
  local i=1 delay=5
  while :; do
    if timeout "$GIT_RETRY_TIMEOUT" git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 "$@"; then
      return 0
    fi
    if [ "$i" -ge "$GIT_RETRY_ATTEMPTS" ]; then
      echo "[-] git $1 gagal setelah ${GIT_RETRY_ATTEMPTS}x percobaan" >&2
      return 1
    fi
    echo "[!] git $* gagal (percobaan ${i}/${GIT_RETRY_ATTEMPTS}) — retry ${delay}s lagi" >&2
    sleep "$delay"
    i=$((i + 1)); delay=$((delay * 2))
  done
}

# git_clone_retry <dest> <clone args (before dest)...> — wipes partial dest between attempts.
git_clone_retry() {
  local dest="$1"; shift
  local i=1 delay=5
  while :; do
    rm -rf "$dest"
    if timeout "$GIT_RETRY_TIMEOUT" git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 clone "$@" "$dest"; then
      return 0
    fi
    rm -rf "$dest"
    if [ "$i" -ge "$GIT_RETRY_ATTEMPTS" ]; then
      echo "[-] git clone gagal setelah ${GIT_RETRY_ATTEMPTS}x percobaan" >&2
      return 1
    fi
    echo "[!] git clone gagal (percobaan ${i}/${GIT_RETRY_ATTEMPTS}) — retry ${delay}s lagi" >&2
    sleep "$delay"
    i=$((i + 1)); delay=$((delay * 2))
  done
}
