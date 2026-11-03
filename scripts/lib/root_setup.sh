#!/bin/bash
set -e

case "$ROOT" in
  sukisu)   ROOT_REPO="https://github.com/sukisu-ultra/sukisu-ultra.git"; REPO_NAME="sukisu-ultra"
            if [ "$VARIANT" == "susfs" ]; then BRANCH="builtin"; PIN_KEY="sukisu_susfs"; PIN_PREFIX="SUKISU_SUSFS"
            else BRANCH="main"; PIN_KEY="sukisu_root"; PIN_PREFIX="SUKISU_ROOT"; fi ;;
  bakasu) ROOT_REPO="https://github.com/Baka-SU/BakaSU.git"; REPO_NAME="BakaSU"; BRANCH="main"
            if [ "$VARIANT" == "susfs" ]; then PIN_KEY="bakasu_susfs"; PIN_PREFIX="BAKASU_SUSFS"
            else PIN_KEY="bakasu_root"; PIN_PREFIX="BAKASU_ROOT"; fi ;;
  ksu-next)
    if [ "$VARIANT" == "susfs" ]; then
      ROOT_REPO="https://github.com/pershoot/KernelSU-Next.git"; REPO_NAME="KernelSU-Next"; BRANCH="dev-susfs"
      PIN_KEY="ksunext_susfs"; PIN_PREFIX="KSUNEXT_SUSFS"
    else
      ROOT_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"; REPO_NAME="KernelSU-Next"; BRANCH="dev"
      PIN_KEY="ksunext_root"; PIN_PREFIX="KSUNEXT_ROOT"
    fi ;;
  *)        REPO_NAME="none" ;;
esac

echo "PIN_KEY=${PIN_KEY:-}" >> "$GITHUB_ENV"
echo "PIN_PREFIX=${PIN_PREFIX:-}" >> "$GITHUB_ENV"

echo "REPO_NAME=$REPO_NAME" >> "$GITHUB_ENV"

rm -rf "$KERNEL_DIR/drivers/kernelsu"

if [ "$VARIANT" == "stock" ]; then
  mkdir -p "$KERNEL_DIR/drivers/kernelsu"
  touch "$KERNEL_DIR/drivers/kernelsu/Kconfig"
  touch "$KERNEL_DIR/drivers/kernelsu/Makefile"
else
  mkdir -p "$MODULES_DIR"
  SKIP_VAR="SKIP_${PIN_PREFIX}"
  if [ "${!SKIP_VAR}" = "true" ]; then
    echo "[!] ${PIN_KEY} di-skip run ini (belum ada pin & slot candidate kepake komponen lain) — tidak build variant ini."
    echo "BUILD_SKIPPED=true" >> "$GITHUB_ENV"
    return 0
  fi

  REF_VAR="${PIN_PREFIX}_REF"
  RESOLVED_SHA="${!REF_VAR}"
  [ -z "$RESOLVED_SHA" ] && { warn "${REF_VAR} kosong — scout.sh belum jalan atau gagal resolve."; return 1; }

  if [ ! -d "$MODULES_DIR/$REPO_NAME" ]; then
    echo "[+] Cloning $REPO_NAME (full history, buat fallback)..."
    git_clone_retry "$MODULES_DIR/$REPO_NAME" -b "$BRANCH" "$ROOT_REPO" || { echo "[-] Root method clone failed/timed out"; return 1; }
  else
    echo "[+] Fetching $REPO_NAME..."
    (cd "$MODULES_DIR/$REPO_NAME" && git_retry fetch origin "$BRANCH") || { echo "[-] Root method fetch failed/timed out"; return 1; }
  fi

  echo "[+] Checkout ${PIN_KEY} @ ${RESOLVED_SHA:0:8} (dari scout.sh)"
  (cd "$MODULES_DIR/$REPO_NAME" && git checkout -B "$BRANCH" --quiet "$RESOLVED_SHA")

  echo "MANAGER_ROOT_NAME=${ROOT}" >> "$GITHUB_ENV"
  echo "MANAGER_REPO_DIR=${MODULES_DIR}/${REPO_NAME}" >> "$GITHUB_ENV"
  cd "$GITHUB_WORKSPACE"

  if [ "$VARIANT" == "susfs" ]; then
    SUSFS_REPO_URL="https://gitlab.com/simonpunk/susfs4ksu.git"
    SUSFS_SKIP_VAR="SKIP_SUSFS4KSU"
    SUSFS_REF_VAR="SUSFS4KSU_REF"

    if [ "${!SUSFS_SKIP_VAR:-}" = "true" ]; then
      echo "[!] ${SUSFS_REF_VAR%_REF} di-skip run ini (belum ada pin & slot candidate kepake komponen lain) — tidak build variant ini."
      echo "BUILD_SKIPPED=true" >> "$GITHUB_ENV"
      return 0
    fi

    SUSFS_DIR="$MODULES_DIR/susfs4ksu"
    SUSFS_BRANCH="gki-android15-6.6"
    SUSFS_TARGET_SHA="${!SUSFS_REF_VAR:-}"
    [ -z "$SUSFS_TARGET_SHA" ] && { warn "${SUSFS_REF_VAR} kosong — scout.sh belum jalan atau gagal resolve."; return 1; }

    if [ ! -d "$SUSFS_DIR" ]; then
      git_clone_retry "$SUSFS_DIR" "$SUSFS_REPO_URL" -b "$SUSFS_BRANCH" || { echo "[-] SUSFS clone failed/timed out"; return 1; }
    else
      (cd "$SUSFS_DIR" && git remote set-url origin "$SUSFS_REPO_URL" && git_retry fetch origin "$SUSFS_BRANCH") || { echo "[-] SUSFS fetch failed/timed out"; return 1; }
    fi

    # ksu-next (pershoot dev-susfs) udah di-rebase ke SuSFS v2.3.0 baru dan manggil
    # susfs_add_sus_type / susfs_add_sus_avd_allowed_by_type, yang gak ada di pin susfs4ksu
    # global. Cuma ksu-next yang pakai susfs4ksu terpisah (manifest .susfs4ksu_next.good,
    # kosong = HEAD branch); root lain tetap di pin global.
    if [ "${ROOT:-}" = "ksu-next" ]; then
      NEXT_SUSFS_PIN=$(jq -r '.susfs4ksu_next.good // empty' "$SCRIPT_DIR/checkpoint/manifest.json" 2>/dev/null || true)
      if [ -n "$NEXT_SUSFS_PIN" ]; then
        SUSFS_TARGET_SHA="$NEXT_SUSFS_PIN"
      else
        SUSFS_TARGET_SHA=$(cd "$SUSFS_DIR" && git rev-parse "origin/$SUSFS_BRANCH")
      fi
      echo "[+] ksu-next: susfs4ksu override -> ${SUSFS_TARGET_SHA:0:8}"
    fi

    echo "[+] Checkout susfs4ksu @ ${SUSFS_TARGET_SHA:0:8} (dari scout.sh)"
    (cd "$SUSFS_DIR" && git checkout --quiet "$SUSFS_TARGET_SHA")
    echo "SUSFS_USED_SHA=${SUSFS_TARGET_SHA}" >> "$GITHUB_ENV"

    if [ "${ROOT:-}" = "ksu-next" ]; then
      for sym in susfs_add_sus_type susfs_add_sus_avd_allowed_by_type; do
        if ! git -C "$SUSFS_DIR" show "${SUSFS_TARGET_SHA}:kernel_patches/fs/susfs.c" | grep -q "$sym"; then
          echo "[-] susfs4ksu @ ${SUSFS_TARGET_SHA:0:8} gak punya ${sym} — ksu-next dev-susfs butuh susfs4ksu lebih baru. Isi .susfs4ksu_next.good di manifest.json."
          return 1
        fi
      done
    fi

    echo "[+] Injecting SUSFS kernel sources..."
    cp "$SUSFS_DIR/kernel_patches/fs/susfs.c" "$KERNEL_DIR/fs/susfs.c"
    cp "$SUSFS_DIR/kernel_patches/include/linux/susfs.h" "$KERNEL_DIR/include/linux/susfs.h"
    [ -f "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" ] && \
      cp "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" "$KERNEL_DIR/include/linux/susfs_def.h"

    SUSFS_DEF_H="$KERNEL_DIR/include/linux/susfs_def.h"
    if [ -f "$SUSFS_DEF_H" ] && ! grep -q "linux/sched.h" "$SUSFS_DEF_H" 2>/dev/null; then
      sed -i '/#include <linux\/bits.h>/a\
#include <linux\/sched.h>\
#include <linux\/thread_info.h>\
#include <linux\/cred.h>\
#include <asm\/current.h>' "$SUSFS_DEF_H"
    fi

    if grep -q "KSU_SUSFS" "$MODULES_DIR/$REPO_NAME/kernel/Kconfig" 2>/dev/null || [ "$ROOT" == "sukisu" ] || [ "$ROOT" == "bakasu" ]; then
      echo "[+] $REPO_NAME already has native SUSFS integration. Skipping patch..."
    else
      echo "[+] Patching $REPO_NAME for SUSFS..."
      if ! (cd "$MODULES_DIR/$REPO_NAME" && \
        patch -p1 --forward -f --reject-file=- \
        < "$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"); then
        warn "SUSFS patch failed to apply to $REPO_NAME (hunk mismatch or missing target) — aborting build instead of continuing without the patch."
        return 1
      fi
    fi
  fi

  if [ ! -d "$MODULES_DIR/$REPO_NAME/kernel/uapi" ] && [ -d "$MODULES_DIR/$REPO_NAME/uapi" ]; then
    ln -sfn ../uapi "$MODULES_DIR/$REPO_NAME/kernel/uapi"
  fi

  echo "[+] Symlinking $REPO_NAME to drivers/kernelsu..."
  ln -sf "$MODULES_DIR/$REPO_NAME/kernel" "$KERNEL_DIR/drivers/kernelsu"
fi

if [ "$VARIANT" == "susfs" ]; then
  # Root managers that already ship the SUSFS v2.3.0 kernel API (preinit + selinux_hide)
  # need no fixup: the legacy script rewrites sucompat.h/selinux.c/rules.c back to the old
  # API and breaks them (e.g. conflicting ksu_handle_faccessat prototypes).
  if grep -qs "ksu_setup_preinit_file" "$MODULES_DIR/$REPO_NAME/kernel/preinit/preinit.c"; then
    echo "[+] $REPO_NAME already implements the SUSFS v2.3.0 kernel API — skipping legacy SUSFS fixup"
  else
    echo "[+] Running SUSFS fixup..."
    bash "$KERNEL_DIR/ksu_susfs_fixup.sh" "$KERNEL_DIR/drivers/kernelsu" "$ROOT"
  fi
fi
