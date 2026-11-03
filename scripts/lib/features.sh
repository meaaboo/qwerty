#!/bin/bash
# Collect what this build REALLY contains, for the Telegram caption.
# Everything is read from the build output (final .config, manager build log, injected
# sources), never from the inputs alone, so a feature that did not get compiled in is
# simply not listed.
# Never fail the build over caption data: the whole body runs inside a function that is called
# with "|| ...", so set -e / the ERR trap in build.sh (which can blacklist pins) never fire here.
_features_main() {

  OUT_CFG="$OUT_DIR/.config"
  BUILD_INFO="$OUT_DIR/.build_info.txt"

  cfg() { grep -qE "^CONFIG_$1=(y|m)$" "$OUT_CFG" 2>/dev/null; }

  ITEMS=()
  MISSING=()

  # HZ (value the kernel was configured with)
  CFG_HZ="$(grep -E '^CONFIG_HZ=' "$OUT_CFG" 2>/dev/null | head -1 | cut -d= -f2)"
  ITEMS+=("${CFG_HZ:-$HZ_ID}Hz")

  # LTO
  if   cfg LTO_CLANG_FULL; then ITEMS+=("Full LTO")
  elif cfg LTO_CLANG_THIN; then ITEMS+=("Thin LTO")
  fi

  # Scheduler / networking / sync
  if cfg SCHED_BORE; then ITEMS+=("BORE Scheduler"); else MISSING+=("BORE (CONFIG_SCHED_BORE)"); fi
  if cfg NTSYNC;     then ITEMS+=("NTSync");         else MISSING+=("NTSync (CONFIG_NTSYNC)"); fi

  TCP=()
  cfg TCP_CONG_BBR3   && TCP+=("BBRv3")
  cfg TCP_CONG_BRUTAL && TCP+=("Brutal")
  if [ "${#TCP[@]}" -gt 0 ]; then
    ITEMS+=("TCP: $(printf '%s\n' "${TCP[@]}" | paste -sd'|' | sed 's/|/ - /g')")
  else
    MISSING+=("TCP (CONFIG_TCP_CONG_BBR3 / CONFIG_TCP_CONG_BRUTAL)")
  fi

  # Re:Kernel (injected by rekernel.sh on every build)
  grep -q 'rekernel' "$KERNEL_DIR/drivers/android/binder.c" 2>/dev/null && ITEMS+=("Re:Kernel")

  # Toggles
  [ "$DROIDSPACES" == "on" ] && ITEMS+=("Droidspaces")
  [ "$DEBUG_MODE" == "on" ]  && ITEMS+=("Debug Mode")
  if [ "$NOMOUNT" == "on" ] && cfg NOMOUNT; then
    ITEMS+=("NoMount${NOMOUNT_VER:+ ${NOMOUNT_VER}}")
  fi

  # SuSFS (version straight from the header that was injected into the kernel)
  if [ "$VARIANT" == "susfs" ] && cfg KSU_SUSFS; then
    SUSFS_V="$(grep -m1 -E '^#define SUSFS_VERSION' "$KERNEL_DIR/include/linux/susfs.h" 2>/dev/null | sed -E 's/.*"([^"]*)".*/\1/')"
    [ -n "$SUSFS_V" ] && [[ "$SUSFS_V" != v* ]] && SUSFS_V="v${SUSFS_V}"
    ITEMS+=("SuSFS${SUSFS_V:+ ${SUSFS_V}}")
  fi

  # Manager line: "<name> <tag> (<build>/<uapi>")
  MANAGER_LINE=""
  case "$ROOT" in
    sukisu)   MGR_NAME="SukiSU-Ultra" ;;
    bakasu)   MGR_NAME="BakaSU" ;;
    ksu-next) MGR_NAME="KernelSU-Next" ;;
    *)        MGR_NAME="" ;;
  esac

  if [ -n "$MGR_NAME" ] && [ "$VARIANT" != "stock" ]; then
    MGR_CODE="" MGR_TAG=""
    if [ -f "$BUILD_INFO" ]; then
      MGR_CODE="$(grep -m1 -oE "^-- (${MGR_NAME}|${REPO_NAME:-$MGR_NAME}) version( code)?: [0-9]+" "$BUILD_INFO" | grep -oE '[0-9]+$' || true)"
      MGR_TAG="$(grep -E ' tag: ' "$BUILD_INFO" | head -1 | sed -E 's/.* tag: *//' || true)"
      if [ -z "$MGR_TAG" ]; then
        NAME_LINE="$(grep -E 'version name: ' "$BUILD_INFO" | head -1 | sed -E 's/.*version name: *//' || true)"
        [ -z "$NAME_LINE" ] && NAME_LINE="$(grep -E 'version: [0-9]+ \[' "$BUILD_INFO" | head -1 | sed -E 's/.*\[(.*)\].*/\1/' || true)"
        MGR_TAG="$(printf '%s' "$NAME_LINE" | sed -E "s/-${BRAND:-DumpC2J}\$//; s/-[0-9a-f]{7,40}(-dirty)?(@.*)?\$//")"
      fi
    fi
    if [ -z "$MGR_TAG" ] && [ -d "$MODULES_DIR/$REPO_NAME/.git" ]; then
      MGR_TAG="$(git -C "$MODULES_DIR/$REPO_NAME" describe --tags --abbrev=0 2>/dev/null || true)"
    fi
    [ -n "$MGR_TAG" ] && [[ "$MGR_TAG" != v* ]] && MGR_TAG="v${MGR_TAG}"

    MGR_UAPI="$(grep -rhoE 'KERNEL_SU_UAPI_VERSION *[=,] *[0-9]+' --include=supercall.h "$MODULES_DIR/$REPO_NAME" 2>/dev/null | head -1 | grep -oE '[0-9]+$' || true)"

    MANAGER_LINE="${MGR_NAME}${MGR_TAG:+ ${MGR_TAG}}"
    if   [ -n "$MGR_CODE" ] && [ -n "$MGR_UAPI" ]; then MANAGER_LINE="${MANAGER_LINE} (${MGR_CODE}/${MGR_UAPI})"
    elif [ -n "$MGR_CODE" ];                       then MANAGER_LINE="${MANAGER_LINE} (${MGR_CODE})"
    fi
  fi

  # Alphabetical, case-insensitive, digits first
  CAPTION_FEATURES="$(printf '%s\n' "${ITEMS[@]}" | LC_ALL=C sort -f)"
  CAPTION_MANAGER="$MANAGER_LINE"

  {
    echo "CAPTION_MANAGER=${CAPTION_MANAGER}"
    echo "CAPTION_FEATURES<<__DUMPC2J_EOF__"
    echo "$CAPTION_FEATURES"
    echo "__DUMPC2J_EOF__"
  } >> "${GITHUB_ENV:-/dev/null}"

  echo "[+] Caption manager : ${CAPTION_MANAGER:-none}"
  echo "[+] Caption features:"
  printf '      • %s\n' "${ITEMS[@]}" | LC_ALL=C sort -f -k2
  if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "[i] Not detected in final .config (hidden from caption, check symbol names if unexpected):"
    printf '      - %s\n' "${MISSING[@]}"
  fi
}

_features_main || echo "[!] features.sh hit an error (non-fatal), caption may be incomplete" >&2
true
