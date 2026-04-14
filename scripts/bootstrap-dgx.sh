#!/usr/bin/env bash
# bootstrap-dgx.sh — idempotent DGX Spark host setup
#
# Installs packages, enables libvirtd, installs arm64 CNI plugins,
# and fixes /dev/kvm permissions.
#
# Run as a regular user with sudo access:
#   bash scripts/bootstrap-dgx.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

log() { echo "[bootstrap] $*"; }

# ---------------------------------------------------------------------------
# 1. Install packages
# ---------------------------------------------------------------------------
log "Updating apt..."
sudo apt-get update -q

log "Installing packages..."
sudo apt-get install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst \
  libvirt-dev cpu-checker ovmf \
  python3 python3-pip python3-venv python3-dev pkg-config \
  curl git jq make gcc perl liblzma-dev mtools \
  qemu-utils kpartx debootstrap squashfs-tools dosfstools gdisk \
  ebtables

# ---------------------------------------------------------------------------
# 2. Enable libvirtd
# ---------------------------------------------------------------------------
log "Enabling libvirtd..."
sudo systemctl enable --now libvirtd

# ---------------------------------------------------------------------------
# 3. User groups
# ---------------------------------------------------------------------------
TARGET_USER="${SUDO_USER:-${USER}}"
for grp in libvirt kvm; do
  if id -nG "${TARGET_USER}" | grep -qw "${grp}"; then
    log "User '${TARGET_USER}' already in group '${grp}'"
  else
    log "Adding '${TARGET_USER}' to group '${grp}'..."
    sudo usermod -aG "${grp}" "${TARGET_USER}"
  fi
done

# ---------------------------------------------------------------------------
# 4. Fix /dev/kvm permissions (DGX Spark sometimes reassigns the group)
# ---------------------------------------------------------------------------
log "Fixing /dev/kvm permissions..."
sudo chown root:kvm /dev/kvm 2>/dev/null || true
sudo chmod 660 /dev/kvm 2>/dev/null || true

if [[ ! -f /etc/udev/rules.d/99-kvm.rules ]]; then
  echo 'SUBSYSTEM=="misc", KERNEL=="kvm", GROUP="kvm", MODE="0660"' | \
    sudo tee /etc/udev/rules.d/99-kvm.rules > /dev/null
  log "Created udev rule for /dev/kvm"
fi

# ---------------------------------------------------------------------------
# 5. Install arm64 CNI plugins
# ---------------------------------------------------------------------------
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.4.0}"
CNI_BIN_DIR="/opt/cni/bin"
ARCH=$(uname -m)

if [[ "${ARCH}" == "aarch64" ]]; then
  CNI_ARCH="arm64"
elif [[ "${ARCH}" == "x86_64" ]]; then
  CNI_ARCH="amd64"
else
  CNI_ARCH="${ARCH}"
fi

if [[ ! -f "${CNI_BIN_DIR}/bridge" ]] || ! file "${CNI_BIN_DIR}/bridge" | grep -qi "${ARCH}"; then
  log "Installing ${CNI_ARCH} CNI plugins ${CNI_PLUGINS_VERSION}..."
  sudo mkdir -p "${CNI_BIN_DIR}"
  curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${CNI_ARCH}-${CNI_PLUGINS_VERSION}.tgz" \
    | sudo tar xz -C "${CNI_BIN_DIR}"
else
  log "CNI plugins already installed"
fi

# ---------------------------------------------------------------------------
# 6. AAVMF/OVMF symlinks
# ---------------------------------------------------------------------------
for pair in "AAVMF_VARS_4M.fd:AAVMF_VARS.fd" "AAVMF_CODE_4M.fd:AAVMF_CODE.fd"; do
  src="/usr/share/AAVMF/${pair%%:*}"
  dst="/usr/share/AAVMF/${pair##*:}"
  if [[ -e "${dst}" ]]; then
    log "AAVMF symlink already exists: ${dst}"
  elif [[ -e "${src}" ]]; then
    log "Creating AAVMF symlink: ${dst} -> ${src}"
    sudo ln -s "${src}" "${dst}"
  fi
done

# ---------------------------------------------------------------------------
# 7. Install Helm
# ---------------------------------------------------------------------------
if command -v helm &>/dev/null; then
  log "Helm already installed"
else
  log "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "====================================================================="
echo " Bootstrap complete."
echo ""
echo " IMPORTANT: Log out and log back in (or run 'newgrp libvirt')"
echo " for group membership to take effect."
echo "====================================================================="
