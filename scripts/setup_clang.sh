#!/bin/bash
set -eo pipefail

CLANG_VARIANT="${1:-neutron}"
TOOLCHAIN_DIR="${HOME}/toolchains/${CLANG_VARIANT}-clang"

if [ "${CLANG_VARIANT}" != "neutron" ] && [ -x "${TOOLCHAIN_DIR}/bin/clang" ]; then
  CLANG_BIN="${TOOLCHAIN_DIR}/bin"
  VER=$("${CLANG_BIN}/clang" --version | head -n1 | grep -oP 'clang version \K[0-9.]+' || echo "cached")
  case "${CLANG_VARIANT}" in
    cirrus) COMPILER_STRING="Cirrus Clang ${VER}" ;;
    aosp)   COMPILER_STRING="AOSP Clang ${VER}" ;;
    weebx)  COMPILER_STRING="WeebX Clang ${VER}" ;;
    zyc)    COMPILER_STRING="ZyC Clang ${VER}" ;;
    *)      COMPILER_STRING="${CLANG_VARIANT} Clang ${VER}" ;;
  esac
  echo "CLANG_VARIANT=${CLANG_VARIANT}" >> "${GITHUB_ENV}"
  echo "CLANG_PATH=${CLANG_BIN}" >> "${GITHUB_ENV}"
  echo "${CLANG_BIN}" >> "${GITHUB_PATH}"
  echo "KBUILD_COMPILER_STRING=${COMPILER_STRING}" >> "${GITHUB_ENV}"
  echo "[+] Clang ready (cached): ${CLANG_BIN}"
  "${CLANG_BIN}/clang" --version
  exit 0
fi

echo "[*] Setting up Clang: ${CLANG_VARIANT}"

case "${CLANG_VARIANT}" in
  neutron)
    mkdir -p "${HOME}/toolchains/neutron-clang"
    cd "${HOME}/toolchains/neutron-clang"
    curl --max-time 60 --retry 3 -Lo antman https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman
    chmod +x antman
    for i in 1 2 3; do
      ./antman -S && break
      echo "[!] antman -S failed (attempt ${i}/3), retrying in 15s..."
      sleep 15
      [ "${i}" -eq 3 ] && { echo "[!] antman -S failed after 3 attempts"; exit 1; }
    done
    for i in 1 2 3; do
      ./antman --patch=glibc && break
      echo "[!] antman --patch=glibc failed (attempt ${i}/3), retrying in 15s..."
      sleep 15
      [ "${i}" -eq 3 ] && { echo "[!] antman --patch=glibc failed after 3 attempts"; exit 1; }
    done
    CLANG_BIN="${HOME}/toolchains/neutron-clang/bin"
    NEUTRON_VER=$("${CLANG_BIN}/clang" --version | head -n1 | grep -oP 'clang version \K[0-9.]+' || echo "latest")
    COMPILER_STRING="Neutron Clang ${NEUTRON_VER}"
    ;;
  cirrus)
    CIRRUS_URL=$(curl -s --max-time 30 https://api.github.com/repos/greenforce-project/greenforce_clang/releases/latest \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((x['browser_download_url'] for x in d.get('assets',[]) if x['name'].endswith('.tar.gz')), ''))")
    if [ -z "${CIRRUS_URL}" ]; then
      echo "[!] Cirrus release not found"
      exit 1
    fi
    echo "[*] Cirrus URL: ${CIRRUS_URL}"
    mkdir -p "${HOME}/toolchains/cirrus-clang"
    curl -fL --retry 5 --retry-delay 15 --retry-all-errors -C - --max-time 300 -o /tmp/cirrus-clang.tar.gz "${CIRRUS_URL}" || { echo "[!] Cirrus clang download failed/timed out"; exit 1; }
    tar -xf /tmp/cirrus-clang.tar.gz -C "${HOME}/toolchains/cirrus-clang" --strip-components=1
    rm /tmp/cirrus-clang.tar.gz
    CLANG_BIN="${HOME}/toolchains/cirrus-clang/bin"
    GF_VERSION=$("${CLANG_BIN}/clang" --version | head -n1 | grep -oP 'clang version \K[0-9.]+' || echo "23.0.0")
    COMPILER_STRING="Cirrus Clang ${GF_VERSION}"
    ;;
  aosp)
    # version/tag come from resolve_aosp_clang.sh (latest); falls back to the pinned known-good pair
    PIN_VER="r596125"; PIN_TAG="android-17.0.0_r1"
    CLANG_VER="${AOSP_CLANG_VER:-$PIN_VER}"
    AOSP_TAG="${AOSP_CLANG_TAG:-$PIN_TAG}"
    mkdir -p "${HOME}/toolchains/aosp-clang"
    AOSP_TGZ="/tmp/aosp-clang.tar.gz"

    # googlesource +archive is generated on the fly: it cannot be resumed (-C -), and 300s is not enough
    # for 500MB+ at runner speeds. Download the whole file on every attempt, then verify the gzip.
    aosp_download() {
      local url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/${2}/clang-${1}.tar.gz" attempt
      for attempt in 1 2 3; do
        rm -f "$AOSP_TGZ"
        if curl -fL --connect-timeout 30 --retry 2 --retry-delay 15 --retry-all-errors --max-time 1200 -o "$AOSP_TGZ" "$url" && gzip -t "$AOSP_TGZ" 2>/dev/null; then
          return 0
        fi
        echo "[!] AOSP clang ${1} download attempt ${attempt}/3 failed or file is corrupt, retrying..."; sleep 20
      done
      return 1
    }

    echo "[*] AOSP clang latest: ${CLANG_VER} (tag: ${AOSP_TAG})"
    if ! aosp_download "$CLANG_VER" "$AOSP_TAG"; then
      if [ "$CLANG_VER" != "$PIN_VER" ]; then
        echo "[!] ${CLANG_VER} download failed, falling back to pinned ${PIN_VER} (${PIN_TAG})"
        CLANG_VER="$PIN_VER"; AOSP_TAG="$PIN_TAG"
        aosp_download "$CLANG_VER" "$AOSP_TAG" || { echo "[!] Failed to download AOSP clang ${CLANG_VER} after retries (server may be down for an extended period)"; exit 1; }
      else
        echo "[!] Failed to download AOSP clang ${CLANG_VER} from tag ${AOSP_TAG} after retries (server may be down for an extended period)"; exit 1
      fi
    fi
    tar -xf /tmp/aosp-clang.tar.gz -C "${HOME}/toolchains/aosp-clang"
    rm /tmp/aosp-clang.tar.gz
    CLANG_BIN="${HOME}/toolchains/aosp-clang/bin"
    AOSP_VER=$("${CLANG_BIN}/clang" --version | head -n1 | grep -oP 'clang version \K[0-9.]+' || echo "${CLANG_VER}")
    COMPILER_STRING="AOSP Clang ${AOSP_VER} (${CLANG_VER})"
    ;;
  weebx)
    WEEBX_URL=$(curl -s --max-time 30 https://raw.githubusercontent.com/XSans0/WeebX-Clang/main/main/link.txt)
    [ -z "${WEEBX_URL}" ] && { echo "[!] WeebX URL not found"; exit 1; }
    mkdir -p "${HOME}/toolchains/weebx-clang"
    curl -fL --retry 5 --retry-delay 15 --retry-all-errors -C - --max-time 300 -o /tmp/weebx-clang.tar.gz "${WEEBX_URL}" || { echo "[!] WeebX clang download failed/timed out"; exit 1; }
    tar -xf /tmp/weebx-clang.tar.gz -C "${HOME}/toolchains/weebx-clang" --strip-components=1
    rm /tmp/weebx-clang.tar.gz
    CLANG_BIN="${HOME}/toolchains/weebx-clang/bin"
    WX_VER=$("${CLANG_BIN}/clang" --version | head -n1 | grep -oP 'clang version \K[0-9.]+' || echo "latest")
    COMPILER_STRING="WeebX Clang ${WX_VER}"
    ;;
  zyc)
    ZYC_URL=$(curl -sL --max-time 30 https://raw.githubusercontent.com/ZyCromerZ/Clang/main/Clang-main-link.txt | tr -d '[:space:]')
    echo "[*] ZyC URL: ${ZYC_URL}"
    mkdir -p "${HOME}/toolchains/zyc-clang"
    if [ -z "$ZYC_URL" ]; then
      echo "[-] ZyC: Clang-main-link.txt is empty or unreachable. ZyC may be down."
      echo "[-] Please choose a different toolchain (neutron/cirrus/weebx)."
      exit 1
    fi
    curl -L --fail --retry 5 --retry-delay 15 --retry-all-errors -C - --max-time 300 -o /tmp/zyc-clang.tar.gz "${ZYC_URL}" || {
      echo "[-] ZyC: download failed. Server may be down."
      echo "[-] Please choose a different toolchain (neutron/cirrus/weebx)."
      exit 1
    }
    echo "[*] ZyC tar structure (first 10):"
    tar -tf /tmp/zyc-clang.tar.gz 2>/dev/null | head -10
    echo "[*] ZyC bin location:"
    tar -tf /tmp/zyc-clang.tar.gz 2>/dev/null | grep -m3 'bin/clang'
    STRIP=0
    BIN_PATH=$(tar -tf /tmp/zyc-clang.tar.gz 2>/dev/null | grep -m1 'bin/clang$')
    [ -z "$BIN_PATH" ] && { echo "[!] bin/clang not found in ZyC tarball"; exit 1; }
    DEPTH=$(echo "$BIN_PATH" | tr '/' '\n' | wc -l)
    STRIP=$(( DEPTH - 2 ))
    [ "$STRIP" -lt 0 ] && STRIP=0
    echo "[*] bin/clang found at: ${BIN_PATH} -> strip-components=${STRIP}"
    tar -xf /tmp/zyc-clang.tar.gz -C "${HOME}/toolchains/zyc-clang" --strip-components=${STRIP}
    rm /tmp/zyc-clang.tar.gz
    CLANG_BIN="${HOME}/toolchains/zyc-clang/bin"
    ZYC_VER=$("${CLANG_BIN}/clang" --version | head -n1 | grep -oP 'clang version \K[0-9.]+' || echo "latest")
    COMPILER_STRING="ZyC Clang ${ZYC_VER}"
    ;;
  *)
    echo "[!] Unknown clang variant: ${CLANG_VARIANT}"
    exit 1
    ;;
esac

echo "CLANG_VARIANT=${CLANG_VARIANT}" >> "${GITHUB_ENV}"
echo "CLANG_PATH=${CLANG_BIN}" >> "${GITHUB_ENV}"
echo "${CLANG_BIN}" >> "${GITHUB_PATH}"
echo "KBUILD_COMPILER_STRING=${COMPILER_STRING}" >> "${GITHUB_ENV}"
echo "[+] Clang ready: ${CLANG_BIN}"
"${CLANG_BIN}/clang" --version
