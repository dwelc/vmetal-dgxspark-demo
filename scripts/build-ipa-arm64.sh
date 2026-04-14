#!/usr/bin/env bash
# build-ipa-arm64.sh — build arm64 IPA ramdisk on the DGX Spark
#
# Builds an Ironic Python Agent (IPA) ramdisk image for aarch64
# using ironic-python-agent-builder with Debian Trixie.
#
# Output: /srv/os-images/ipa-arm64.{kernel,initramfs}
#
# Must run on the DGX Spark (arm64 host) — cross-compilation is not supported.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/srv/os-images}"
IPA_VENV="${HOME}/ipa-builder"
IPA_OUTPUT="/tmp/ipa-arm64"

log() { echo "[build-ipa] $*"; }

# ---------------------------------------------------------------------------
# 1. Install builder
# ---------------------------------------------------------------------------
if [[ ! -x "${IPA_VENV}/bin/ironic-python-agent-builder" ]]; then
  log "Creating builder venv..."
  python3 -m venv "${IPA_VENV}"
  "${IPA_VENV}/bin/pip" install --quiet --upgrade pip
  "${IPA_VENV}/bin/pip" install --quiet diskimage-builder ironic-python-agent-builder
fi

# ---------------------------------------------------------------------------
# 2. Check for existing build
# ---------------------------------------------------------------------------
if [[ -f "${IMAGE_CACHE_DIR}/ipa-arm64.kernel" && -f "${IMAGE_CACHE_DIR}/ipa-arm64.initramfs" ]]; then
  log "arm64 IPA already exists at ${IMAGE_CACHE_DIR}/ipa-arm64.{kernel,initramfs}"
  log "Delete them to rebuild."
  ls -lh "${IMAGE_CACHE_DIR}/ipa-arm64."*
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Build
# ---------------------------------------------------------------------------
log "Building arm64 IPA ramdisk (Debian Trixie)..."
log "This takes 2-5 minutes."

source "${IPA_VENV}/bin/activate"
export ARCH=arm64
ironic-python-agent-builder -o "${IPA_OUTPUT}" --release trixie debian-minimal

# ---------------------------------------------------------------------------
# 4. Copy to image server
# ---------------------------------------------------------------------------
sudo mkdir -p "${IMAGE_CACHE_DIR}"
sudo cp "${IPA_OUTPUT}.kernel" "${IMAGE_CACHE_DIR}/ipa-arm64.kernel"
sudo cp "${IPA_OUTPUT}.initramfs" "${IMAGE_CACHE_DIR}/ipa-arm64.initramfs"

# ---------------------------------------------------------------------------
# 5. Create tarball for the IPA downloader init container
#
# The ironic-ipa-downloader expects a .tar.gz containing files named
# <basename>.kernel and <basename>.initramfs where <basename> matches
# the tarball name minus .tar.gz.
#
# By serving this from the DGX Spark's image server and setting
# IPA_BASEURI + IPA_FILENAME on the init container, the downloader
# will fetch the arm64 IPA automatically on every pod restart.
# ---------------------------------------------------------------------------
TARBALL_NAME="ipa-arm64"
TARBALL_DIR="/tmp/${TARBALL_NAME}-tarball"

log "Creating IPA tarball for ironic-ipa-downloader..."
rm -rf "${TARBALL_DIR}"
mkdir -p "${TARBALL_DIR}"
cp "${IPA_OUTPUT}.kernel" "${TARBALL_DIR}/${TARBALL_NAME}.kernel"
cp "${IPA_OUTPUT}.initramfs" "${TARBALL_DIR}/${TARBALL_NAME}.initramfs"
tar czf "${IMAGE_CACHE_DIR}/${TARBALL_NAME}.tar.gz" -C "${TARBALL_DIR}" .
rm -rf "${TARBALL_DIR}"

echo ""
echo "====================================================================="
echo " arm64 IPA ramdisk built successfully."
echo ""
ls -lh "${IMAGE_CACHE_DIR}/ipa-arm64."*
ls -lh "${IMAGE_CACHE_DIR}/${TARBALL_NAME}.tar.gz"
echo ""
echo " The tarball is served at:"
echo "   http://172.22.0.1:9000/${TARBALL_NAME}.tar.gz"
echo ""
echo " The NodeProvider configures the IPA downloader to fetch from"
echo " this URL automatically on every metal3 pod restart."
echo ""
echo " Next: bash scripts/setup-tftp.sh"
echo "====================================================================="
