#!/bin/bash
set -e

BBG_DIR="$KERNEL_DIR/Baseband-guard"
if [ ! -d "$BBG_DIR" ]; then
  git_clone_retry "$BBG_DIR" --depth=1 https://github.com/vc-teahouse/Baseband-guard.git || { echo "[!] Baseband-guard clone failed/timed out"; exit 1; }
else
  (cd "$BBG_DIR" && git_retry fetch origin && git reset --hard origin/main || echo "[!] Baseband-guard update failed, using stale checkout")
fi
echo "[+] Running Baseband-guard setup..."
(cd "$KERNEL_DIR" && sh "$BBG_DIR/setup.sh")
