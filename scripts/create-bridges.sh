#!/usr/bin/env bash
# create-bridges.sh — create the provisioning bridge on the DGX Spark
#
# Creates br-provision with STP disabled and NAT masquerade.
# Safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROVISION_BRIDGE="${PROVISION_BRIDGE:-br-provision}"
PROVISION_BRIDGE_IP="${PROVISION_BRIDGE_IP:-172.22.0.1}"
PROVISION_CIDR="${PROVISION_CIDR:-172.22.0.0/24}"
LAN_INTERFACE="${LAN_INTERFACE:-enP7s7}"

[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

log() { echo "[create-bridges] $*"; }

# ---------------------------------------------------------------------------
# Check if bridge exists
# ---------------------------------------------------------------------------
if ip link show "${PROVISION_BRIDGE}" &>/dev/null; then
  log "Bridge '${PROVISION_BRIDGE}' already exists."
  ip addr show "${PROVISION_BRIDGE}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Create bridge
# ---------------------------------------------------------------------------
log "Creating bridge '${PROVISION_BRIDGE}'..."
sudo ip link add name "${PROVISION_BRIDGE}" type bridge
sudo ip link set "${PROVISION_BRIDGE}" type bridge stp_state 0
sudo ip addr add "${PROVISION_BRIDGE_IP}/24" dev "${PROVISION_BRIDGE}"
sudo ip link set "${PROVISION_BRIDGE}" up

# Persist via systemd-networkd
NETDEV_FILE="/etc/systemd/network/10-${PROVISION_BRIDGE}.netdev"
NETWORK_FILE="/etc/systemd/network/10-${PROVISION_BRIDGE}.network"

if [[ ! -f "${NETDEV_FILE}" ]]; then
  sudo tee "${NETDEV_FILE}" > /dev/null <<EOF
[NetDev]
Name=${PROVISION_BRIDGE}
Kind=bridge

[Bridge]
STP=no
EOF
fi

if [[ ! -f "${NETWORK_FILE}" ]]; then
  sudo tee "${NETWORK_FILE}" > /dev/null <<EOF
[Match]
Name=${PROVISION_BRIDGE}

[Network]
Address=${PROVISION_BRIDGE_IP}/24
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF
fi

sudo systemctl reload-or-restart systemd-networkd 2>/dev/null || true

# ---------------------------------------------------------------------------
# NAT masquerade
# ---------------------------------------------------------------------------
log "Enabling IP forwarding and NAT..."
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-vmetal-forward.conf > /dev/null

if ! sudo iptables -C FORWARD -i "${PROVISION_BRIDGE}" -o "${LAN_INTERFACE}" -j ACCEPT 2>/dev/null; then
  sudo iptables -I FORWARD 1 -i "${PROVISION_BRIDGE}" -o "${LAN_INTERFACE}" -j ACCEPT
fi
if ! sudo iptables -C FORWARD -i "${LAN_INTERFACE}" -o "${PROVISION_BRIDGE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
  sudo iptables -I FORWARD 2 -i "${LAN_INTERFACE}" -o "${PROVISION_BRIDGE}" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi
if ! sudo iptables -t nat -C POSTROUTING -s "${PROVISION_CIDR}" ! -d "${PROVISION_CIDR}" -o "${LAN_INTERFACE}" -j MASQUERADE 2>/dev/null; then
  sudo iptables -t nat -A POSTROUTING -s "${PROVISION_CIDR}" ! -d "${PROVISION_CIDR}" -o "${LAN_INTERFACE}" -j MASQUERADE
fi

if ! command -v netfilter-persistent &>/dev/null; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
fi
sudo netfilter-persistent save

log "Bridge '${PROVISION_BRIDGE}' is up:"
ip addr show "${PROVISION_BRIDGE}"
