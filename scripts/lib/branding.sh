#!/bin/bash
set -e

[ -n "$MODULES_DIR" ] && [ -n "$REPO_NAME" ] || return 0

echo "[+] Applying custom kernel branding: ${BRAND}"
for f in Makefile Kbuild; do
  target="$MODULES_DIR/$REPO_NAME/kernel/$f"
  [ -f "$target" ] && python3 "${BUILDER_DIR}/scripts/branding.py" "$target" "$BRAND"
done
true
