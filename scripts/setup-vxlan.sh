#!/usr/bin/env bash
# setup-vxlan.sh — create VXLAN tunnel on the DGX Spark
#
# Extends br-provision to a remote k3s node so Metal3/Ironic pods
# (which run on x86) can reach VMs on the DGX Spark's provisioning network.
#
# This script runs on the DGX Spark. It also prints the commands
# to run on the remote k3s node.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROVISION_BRIDGE="${PROVISION_BRIDGE:-br-provision}"
VXLAN_REMOTE_IP="${VXLAN_REMOTE_IP:-192.168.1.102}"
VXLAN_LOCAL_DEV="${VXLAN_LOCAL_DEV:-enP7s7}"
VXLAN_REMOTE_DEV="${VXLAN_REMOTE_DEV:-enp2s0}"
VXLAN_ID="${VXLAN_ID:-100}"
VXLAN_DSTPORT="${VXLAN_DSTPORT:-4789}"
LAN_IP="${LAN_IP:-192.168.1.101}"

[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

log() { echo "[vxlan] $*"; }

# ---------------------------------------------------------------------------
# DGX Spark side — runtime
# ---------------------------------------------------------------------------
if ip link show vxlan${VXLAN_ID} &>/dev/null; then
  log "vxlan${VXLAN_ID} already exists on DGX Spark"
else
  log "Creating vxlan${VXLAN_ID} → ${VXLAN_REMOTE_IP}..."
  sudo ip link add vxlan${VXLAN_ID} type vxlan \
    id ${VXLAN_ID} remote ${VXLAN_REMOTE_IP} dstport ${VXLAN_DSTPORT} dev ${VXLAN_LOCAL_DEV}
  sudo ip link set vxlan${VXLAN_ID} master ${PROVISION_BRIDGE} up
  log "VXLAN tunnel created on DGX Spark"
fi

# Enable br_netfilter for iptables on bridged traffic
sudo modprobe br_netfilter
sudo sysctl -w net.bridge.bridge-nf-call-iptables=1 > /dev/null

# ---------------------------------------------------------------------------
# DGX Spark side — persist via systemd-networkd
# ---------------------------------------------------------------------------
VX_NETDEV="/etc/systemd/network/20-vxlan${VXLAN_ID}.netdev"
VX_NETWORK="/etc/systemd/network/20-vxlan${VXLAN_ID}.network"

if [[ ! -f "${VX_NETDEV}" ]]; then
  log "Persisting vxlan${VXLAN_ID} to ${VX_NETDEV}"
  sudo tee "${VX_NETDEV}" > /dev/null <<EOF
[NetDev]
Name=vxlan${VXLAN_ID}
Kind=vxlan

[VXLAN]
VNI=${VXLAN_ID}
Remote=${VXLAN_REMOTE_IP}
Local=${LAN_IP}
DestinationPort=${VXLAN_DSTPORT}
EOF
fi

if [[ ! -f "${VX_NETWORK}" ]]; then
  log "Persisting vxlan${VXLAN_ID} network to ${VX_NETWORK}"
  sudo tee "${VX_NETWORK}" > /dev/null <<EOF
[Match]
Name=vxlan${VXLAN_ID}

[Network]
Bridge=${PROVISION_BRIDGE}
EOF
fi

sudo systemctl reload-or-restart systemd-networkd 2>/dev/null || true

# ---------------------------------------------------------------------------
# Point the user at the k3s-side script
# ---------------------------------------------------------------------------
echo ""
echo "====================================================================="
echo " DGX Spark VXLAN setup complete (and persisted via systemd-networkd)."
echo ""
echo " Now run the matching script on the k3s node (${VXLAN_REMOTE_IP}):"
echo ""
echo "   bash scripts/setup-vxlan-k3s.sh"
echo ""
echo " It creates br-provision + vxlan${VXLAN_ID} on the k3s node, persists"
echo " both via systemd-networkd, and ping-tests 172.22.0.1 at the end."
echo "====================================================================="
