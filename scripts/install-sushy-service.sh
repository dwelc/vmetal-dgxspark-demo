#!/usr/bin/env bash
# install-sushy-service.sh — install sushy-tools as a systemd service

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SUSHY_PORT="${SUSHY_PORT:-8000}"
SUSHY_LIBVIRT_URI="${SUSHY_LIBVIRT_URI:-qemu:///system}"
SUSHY_LISTEN_IP="${SUSHY_LISTEN_IP:-}"
SUSHY_VENV="${SUSHY_VENV:-/opt/sushy-tools}"
SUSHY_CONF_DIR="${SUSHY_CONF_DIR:-/etc/sushy-tools}"

[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

CONF_SRC="${REPO_ROOT}/configs/sushy-tools.conf"
CONF_DEST="${SUSHY_CONF_DIR}/emulator.conf"

log() { echo "[sushy] $*"; }

if [[ ! -x "${SUSHY_VENV}/bin/python3" ]]; then
  log "Creating Python venv at ${SUSHY_VENV}..."
  sudo python3 -m venv "${SUSHY_VENV}"
fi

log "Installing sushy-tools..."
sudo "${SUSHY_VENV}/bin/pip" install --quiet --upgrade pip
sudo "${SUSHY_VENV}/bin/pip" install --quiet sushy-tools libvirt-python

log "Deploying config..."
sudo mkdir -p "${SUSHY_CONF_DIR}"
sudo cp "${CONF_SRC}" "${CONF_DEST}"

[[ -n "${SUSHY_PORT}" ]] && sudo sed -i "s|^SUSHY_EMULATOR_LISTEN_PORT = .*|SUSHY_EMULATOR_LISTEN_PORT = ${SUSHY_PORT}|" "${CONF_DEST}"
[[ -n "${SUSHY_LIBVIRT_URI}" ]] && sudo sed -i "s|^SUSHY_EMULATOR_LIBVIRT_URI = .*|SUSHY_EMULATOR_LIBVIRT_URI = u'${SUSHY_LIBVIRT_URI}'|" "${CONF_DEST}"
[[ -n "${SUSHY_LISTEN_IP}" ]] && sudo sed -i "s|^SUSHY_EMULATOR_LISTEN_IP = .*|SUSHY_EMULATOR_LISTEN_IP = u'${SUSHY_LISTEN_IP}'|" "${CONF_DEST}"

sudo tee /etc/systemd/system/sushy-tools.service > /dev/null <<EOF
[Unit]
Description=Sushy Tools Redfish Emulator
After=network.target libvirtd.service
Requires=libvirtd.service

[Service]
Type=simple
ExecStart=${SUSHY_VENV}/bin/sushy-emulator --config ${CONF_DEST}
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now sushy-tools
sleep 2

if sudo systemctl is-active --quiet sushy-tools; then
  log "sushy-tools is running on port ${SUSHY_PORT}."
else
  sudo systemctl status sushy-tools --no-pager || true
  exit 1
fi
