#!/usr/bin/env bash
# cache-os-image.sh — download arm64 Ubuntu OS image and start HTTP server

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

PROVISION_BRIDGE_IP="${PROVISION_BRIDGE_IP:-172.22.0.1}"
IMAGE_SERVER_PORT="${IMAGE_SERVER_PORT:-9000}"
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/srv/os-images}"

UBUNTU_IMAGE_URL="${UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img}"
UBUNTU_IMAGE_FILE="${UBUNTU_IMAGE_FILE:-ubuntu-24.04-minimal-cloudimg-arm64.img}"

log() { echo "[cache-os-image] $*"; }

sudo mkdir -p "${IMAGE_CACHE_DIR}"
sudo chown "$(id -u):$(id -g)" "${IMAGE_CACHE_DIR}"

DEST="${IMAGE_CACHE_DIR}/${UBUNTU_IMAGE_FILE}"

if [[ -f "${DEST}" ]]; then
  log "Image already cached at ${DEST}"
else
  log "Downloading arm64 Ubuntu 24.04 minimal cloud image..."
  curl -fL --progress-bar "${UBUNTU_IMAGE_URL}" -o "${DEST}.tmp"
  mv "${DEST}.tmp" "${DEST}"
  log "Download complete."
fi

# ---------------------------------------------------------------------------
# Install and start image server
# ---------------------------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/os-image-server.service"

if [[ ! -f "${SERVICE_FILE}" ]]; then
  log "Installing os-image-server service..."
  sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=OS Image HTTP Server for Metal3/Ironic
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server ${IMAGE_SERVER_PORT} --bind ${PROVISION_BRIDGE_IP} --directory ${IMAGE_CACHE_DIR}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
fi

sudo systemctl daemon-reload
sudo systemctl enable --now os-image-server
sudo systemctl restart os-image-server
sleep 1

LOCAL_URL="http://${PROVISION_BRIDGE_IP}:${IMAGE_SERVER_PORT}/${UBUNTU_IMAGE_FILE}"
if curl -fsSI "${LOCAL_URL}" > /dev/null 2>&1; then
  log "Image reachable at ${LOCAL_URL}"
else
  log "ERROR: Image not reachable at ${LOCAL_URL}"
  exit 1
fi

echo ""
echo "====================================================================="
echo " OS image cached and served locally."
echo " URL: ${LOCAL_URL}"
echo "====================================================================="
