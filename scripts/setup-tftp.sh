#!/usr/bin/env bash
# setup-tftp.sh — set up dnsmasq as ProxyDHCP + TFTP server on the DGX Spark
#
# The vCluster Platform DHCP proxy's built-in TFTP server has a Go TFTP
# implementation that is incompatible with the AAVMF UEFI PXE client
# (option negotiation causes "User aborted" errors). This script sets up
# dnsmasq on the DGX Spark as a ProxyDHCP server that overrides the TFTP
# server address to the DGX Spark's own IP, where dnsmasq serves the
# arm64 iPXE binary.
#
# Also builds iPXE (snponly.efi) for arm64 from source.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

PROVISION_BRIDGE="${PROVISION_BRIDGE:-br-provision}"
PROVISION_BRIDGE_IP="${PROVISION_BRIDGE_IP:-172.22.0.1}"
PROVISION_CIDR="${PROVISION_CIDR:-172.22.0.0/24}"
TFTP_ROOT="/srv/tftp"

log() { echo "[setup-tftp] $*"; }

# ---------------------------------------------------------------------------
# 1. Build arm64 iPXE from source
# ---------------------------------------------------------------------------
if [[ -f "${TFTP_ROOT}/snp-arm64.efi" ]]; then
  log "iPXE arm64 binary already exists"
else
  log "Building arm64 iPXE from source..."
  IPXE_DIR="/tmp/ipxe"
  if [[ ! -d "${IPXE_DIR}" ]]; then
    git clone --depth 1 https://github.com/ipxe/ipxe.git "${IPXE_DIR}"
  fi
  cd "${IPXE_DIR}/src"
  make -j$(nproc) bin-arm64-efi/snponly.efi
  sudo mkdir -p "${TFTP_ROOT}"
  sudo cp bin-arm64-efi/snponly.efi "${TFTP_ROOT}/snp-arm64.efi"
  cd "${REPO_ROOT}"
  log "iPXE built: ${TFTP_ROOT}/snp-arm64.efi"
fi

# ---------------------------------------------------------------------------
# 2. Install dnsmasq ProxyDHCP + TFTP service
# ---------------------------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/dnsmasq-tftp.service"

log "Installing dnsmasq ProxyDHCP + TFTP service..."
sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=ProxyDHCP + TFTP for PXE boot (dnsmasq)
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq \\
  --enable-tftp \\
  --tftp-root=${TFTP_ROOT} \\
  --port=0 \\
  --dhcp-range=${PROVISION_CIDR%/*},proxy \\
  --pxe-prompt="PXE" \\
  --pxe-service=ARM64_EFI,"PXE boot",snp-arm64.efi \\
  --interface=${PROVISION_BRIDGE} \\
  --bind-interfaces \\
  --no-daemon \\
  --log-queries \\
  --log-facility=-
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now dnsmasq-tftp

sleep 2
if sudo systemctl is-active --quiet dnsmasq-tftp; then
  log "dnsmasq ProxyDHCP + TFTP is running."
else
  sudo systemctl status dnsmasq-tftp --no-pager || true
  exit 1
fi

echo ""
echo "====================================================================="
echo " ProxyDHCP + TFTP setup complete."
echo ""
echo " TFTP root : ${TFTP_ROOT}"
echo " iPXE file : ${TFTP_ROOT}/snp-arm64.efi"
echo " ProxyDHCP : ${PROVISION_BRIDGE} (${PROVISION_CIDR})"
echo ""
echo " This overrides the DHCP proxy's TFTP server address so"
echo " UEFI PXE clients get iPXE from ${PROVISION_BRIDGE_IP}"
echo " instead of the broken container TFTP."
echo "====================================================================="
