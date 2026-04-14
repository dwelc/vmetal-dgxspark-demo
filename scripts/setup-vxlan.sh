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
# DGX Spark side
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
# Print commands for remote k3s node
# ---------------------------------------------------------------------------
echo ""
echo "====================================================================="
echo " DGX Spark VXLAN setup complete."
echo ""
echo " Now run these commands on the k3s node (${VXLAN_REMOTE_IP}):"
echo ""
echo "   sudo ip link add br-provision type bridge"
echo "   sudo ip link set br-provision type bridge stp_state 0"
echo "   sudo ip link set br-provision up"
echo "   sudo ip link add vxlan${VXLAN_ID} type vxlan \\"
echo "     id ${VXLAN_ID} remote ${LAN_IP} dstport ${VXLAN_DSTPORT} dev ${VXLAN_REMOTE_DEV}"
echo "   sudo ip link set vxlan${VXLAN_ID} master br-provision up"
echo ""
echo " Then verify connectivity:"
echo "   sudo ip addr add 172.22.0.3/24 dev br-provision"
echo "   ping -c 2 172.22.0.1"
echo "   sudo ip addr del 172.22.0.3/24 dev br-provision"
echo "====================================================================="
