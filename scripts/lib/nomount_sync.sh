#!/bin/bash
# Sync NoMount before compile (only when NOMOUNT=on).
#
# Source order, first one that works wins:
#   1. upstream (fresh clone, full history, 3 tries)
#   2. last known-good copy saved by an earlier successful build (hidden git ref)
#   3. the copy already committed in the kernel tree
#
# Whatever ends up in fs/nomount is exactly what gets labelled, so the label
# (NOMOUNT_VER, e.g. "v2.2.0 (605)") always matches what was compiled.
# Ref defaults to branch "dev"; override with NOMOUNT_REF (branch, tag, or SHA).
set -e

if [ "$NOMOUNT" != "on" ]; then
  echo "[nomount] disabled, skipping sync"
  return 0
fi

NOMOUNT_REPO="${NOMOUNT_REPO:-https://github.com/maxsteeel/nomount.git}"
NOMOUNT_REF="${NOMOUNT_REF:-dev}"
NM_STORE_REF="refs/store/nomount"
NM_STORE_FILE="nomount-lastgood.tar.gz"
NM_STORE_REMOTE="${NM_STORE_REMOTE:-${GITHUB_REPOSITORY:+https://github.com/${GITHUB_REPOSITORY}.git}}"
NM_GIT_AUTH=()
[ -n "${GH_TOKEN:-}" ] && NM_GIT_AUTH=(-c "http.extraheader=Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)")
NM_WORK="$(mktemp -d)"
NM_DEST="$KERNEL_DIR/fs/nomount"

NOMOUNT_SRC="" NOMOUNT_SHA="" NOMOUNT_TAG="" NOMOUNT_COUNT="" NOMOUNT_VER=""

# Copy a kernel/src directory into the kernel tree and make sure the fs hooks exist.
_nm_install() {
  rm -rf "$NM_DEST"
  mkdir -p "$NM_DEST"
  cp -a "$1"/. "$NM_DEST"/

  if ! grep -q "nomount" "$KERNEL_DIR/fs/Makefile"; then
    printf '\nobj-$(CONFIG_NOMOUNT) += nomount/\n' >> "$KERNEL_DIR/fs/Makefile"
    echo "[nomount] added hook to fs/Makefile"
  fi
  if ! grep -q 'source "fs/nomount/Kconfig"' "$KERNEL_DIR/fs/Kconfig"; then
    awk '/^endmenu/ { last = NR } { l[NR] = $0 }
         END { for (i = 1; i <= NR; i++) { if (i == last) print "source \"fs/nomount/Kconfig\""; print l[i] } }' \
      "$KERNEL_DIR/fs/Kconfig" > "$KERNEL_DIR/fs/Kconfig.tmp" && mv "$KERNEL_DIR/fs/Kconfig.tmp" "$KERNEL_DIR/fs/Kconfig"
    echo "[nomount] added hook to fs/Kconfig"
  fi
}

# NoMount's own Makefile only embeds the commit count when it can find its .git,
# which never exists inside the kernel tree. Stamp it into the header so the
# kernel reports the same "(count)" that the Telegram caption shows.
_nm_stamp_count() {
  local count="$1" hdr="$NM_DEST/nomount.h"
  if [ -f "$hdr" ] && grep -q '^#define NOMOUNT_BASE_VERSION ' "$hdr"; then
    sed -i "s|^#define NOMOUNT_BASE_VERSION .*|&\n#ifndef NOMOUNT_COMMIT_COUNT\n#define NOMOUNT_COMMIT_COUNT \"${count}\"\n#endif|" "$hdr"
    echo "[nomount] stamped commit count ${count} into nomount.h"
  else
    echo "[nomount] WARN: BASE_VERSION line not found in nomount.h, kernel will not report the commit count" >&2
  fi
}

# 1. upstream
_nm_try_upstream() {
  local dir="$NM_WORK/upstream"
  rm -rf "$dir"
  if ! timeout 180 git clone --quiet --filter=blob:none -b "$NOMOUNT_REF" "$NOMOUNT_REPO" "$dir" 2>/dev/null; then
    # NOMOUNT_REF may be a bare commit SHA, which clone -b cannot take
    rm -rf "$dir"
    timeout 180 git clone --quiet --filter=blob:none "$NOMOUNT_REPO" "$dir" 2>/dev/null || return 1
    git -C "$dir" checkout --quiet "$NOMOUNT_REF" 2>/dev/null || return 1
  fi
  [ -f "$dir/kernel/src/Kconfig" ] && [ -f "$dir/kernel/src/Makefile" ] || {
    echo "[nomount] upstream kernel/src layout changed (Kconfig/Makefile missing)" >&2
    return 1
  }
  NOMOUNT_SHA="$(git -C "$dir" rev-parse HEAD)"
  NOMOUNT_COUNT="$(git -C "$dir" rev-list --count HEAD 2>/dev/null || true)"
  NOMOUNT_TAG="$(git -C "$dir" describe --tags --abbrev=0 2>/dev/null || true)"
  [ -n "$NOMOUNT_TAG" ] || NOMOUNT_TAG="dev-${NOMOUNT_SHA:0:7}"
  NM_SRC_DIR="$dir/kernel/src"
  NOMOUNT_SRC="upstream"
}

# 2. last known-good copy
_nm_try_lastgood() {
  [ -n "$NM_STORE_REMOTE" ] || return 1
  local dir="$NM_WORK/lastgood" repo="$NM_WORK/store-fetch"
  mkdir -p "$dir" "$repo"
  git -C "$repo" init -q
  timeout 60 git "${NM_GIT_AUTH[@]}" -C "$repo" fetch -q --depth=1 "$NM_STORE_REMOTE" "$NM_STORE_REF" 2>/dev/null || return 1
  git -C "$repo" show "FETCH_HEAD:$NM_STORE_FILE" > "$NM_WORK/$NM_STORE_FILE" 2>/dev/null || return 1
  tar -xzf "$NM_WORK/$NM_STORE_FILE" -C "$dir" || return 1
  [ -f "$dir/VERSION" ] && [ -f "$dir/src/Kconfig" ] && [ -f "$dir/src/Makefile" ] || return 1
  NOMOUNT_TAG="$(sed -n 1p "$dir/VERSION")"
  NOMOUNT_COUNT="$(sed -n 2p "$dir/VERSION")"
  NOMOUNT_SHA="$(sed -n 3p "$dir/VERSION")"
  NM_SRC_DIR="$dir/src"
  NOMOUNT_SRC="last-good"
}

# Save what we just used so a later failed download can fall back to it.
_nm_save_lastgood() {
  [ -n "$NM_STORE_REMOTE" ] && [ -n "${GH_TOKEN:-}" ] || return 0
  local pack="$NM_WORK/pack" repo="$NM_WORK/store-push"
  mkdir -p "$pack/src" "$repo"
  cp -a "$NM_SRC_DIR"/. "$pack/src"/
  printf '%s\n%s\n%s\n' "$NOMOUNT_TAG" "$NOMOUNT_COUNT" "$NOMOUNT_SHA" > "$pack/VERSION"
  tar -czf "$repo/$NM_STORE_FILE" -C "$pack" .
  (
    git -C "$repo" init -q
    git -C "$repo" add "$NM_STORE_FILE"
    git -C "$repo" -c user.name="meow bot" -c user.email="bot@meow" \
      commit -q -m "nomount ${NOMOUNT_TAG} (${NOMOUNT_COUNT}) ${NOMOUNT_SHA}"
    timeout 60 git "${NM_GIT_AUTH[@]}" -C "$repo" push -q -f "$NM_STORE_REMOTE" "HEAD:$NM_STORE_REF"
  ) >/dev/null 2>&1 && echo "[nomount] saved last-good copy (${NOMOUNT_TAG} (${NOMOUNT_COUNT}))" \
    || echo "[nomount] WARN: could not save last-good copy (non-fatal)" >&2
}

NM_SRC_DIR=""
echo "[nomount] syncing ${NOMOUNT_REF} from ${NOMOUNT_REPO}"
for attempt in 1 2 3; do
  if _nm_try_upstream; then break; fi
  echo "[nomount] upstream attempt ${attempt}/3 failed" >&2
  [ "$attempt" -lt 3 ] && sleep 5
done

if [ -z "$NOMOUNT_SRC" ]; then
  echo "[nomount] upstream unavailable, trying last known-good copy" >&2
  _nm_try_lastgood || true
fi

if [ -n "$NOMOUNT_SRC" ]; then
  _nm_install "$NM_SRC_DIR"
  [ -n "$NOMOUNT_COUNT" ] && _nm_stamp_count "$NOMOUNT_COUNT"
  if [ -n "$NOMOUNT_COUNT" ]; then NOMOUNT_VER="${NOMOUNT_TAG} (${NOMOUNT_COUNT})"; else NOMOUNT_VER="${NOMOUNT_TAG}"; fi
  if [ "$NOMOUNT_SRC" = "upstream" ]; then _nm_save_lastgood || true; fi
else
  # 3. copy already in the kernel tree: only the base version is provable from source
  echo "[nomount] WARN: no upstream and no last-good copy, using NoMount already in kernel tree" >&2
  NOMOUNT_SRC="in-tree"
  NOMOUNT_SHA="in-tree"
  base="$(grep -m1 '^#define NOMOUNT_BASE_VERSION ' "$NM_DEST/nomount.h" 2>/dev/null | sed -E 's/.*"([0-9]+)".*/\1/')"
  if [ -n "$base" ]; then NOMOUNT_VER="v${base:0:1}.${base:1}"; else NOMOUNT_VER=""; fi
fi

{
  echo "NOMOUNT_SHA=${NOMOUNT_SHA}"
  echo "NOMOUNT_VER=${NOMOUNT_VER}"
  echo "NOMOUNT_SRC=${NOMOUNT_SRC}"
} >> "${GITHUB_ENV:-/dev/null}"
echo "[+] NoMount: ${NOMOUNT_VER:-unknown} (source: ${NOMOUNT_SRC})"
rm -rf "$NM_WORK"
