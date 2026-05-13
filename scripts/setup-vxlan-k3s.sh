#!/usr/bin/env bash
# setup-vxlan-k3s.sh — bring up the k3s-side end of the VXLAN tunnel.
#
# Creates br-provision (no IP, STP off) and vxlan100 on the k3s node where
# Metal3/Ironic pods are scheduled. Persisted via systemd-networkd so the
# tunnel survives reboots/power cycles.
#
# Run this on the k3s node (typically dan-dev-1) AFTER running setup-vxlan.sh
# on the DGX Spark. Safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROVISION_BRIDGE="${PROVISION_BRIDGE:-br-provision}"
VXLAN_REMOTE_IP="${VXLAN_REMOTE_IP:-192.168.1.101}"    # the DGX Spark
VXLAN_LOCAL_IP="${VXLAN_LOCAL_IP:-192.168.1.102}"      # this k3s node
VXLAN_LOCAL_DEV="${VXLAN_LOCAL_DEV:-enp2s0}"
VXLAN_ID="${VXLAN_ID:-100}"
VXLAN_DSTPORT="${VXLAN_DSTPORT:-4789}"

[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

log() { echo "[setup-vxlan-k3s] $*"; }

# ---------------------------------------------------------------------------
# Runtime: create bridge if missing, attach vxlan
# ---------------------------------------------------------------------------
if ip link show "${PROVISION_BRIDGE}" &>/dev/null; then
  log "Bridge '${PROVISION_BRIDGE}' already exists."
else
  log "Creating bridge '${PROVISION_BRIDGE}'..."
  sudo ip link add "${PROVISION_BRIDGE}" type bridge
  sudo ip link set "${PROVISION_BRIDGE}" type bridge stp_state 0
  sudo ip link set "${PROVISION_BRIDGE}" up
fi

if ip link show vxlan${VXLAN_ID} &>/dev/null; then
  log "vxlan${VXLAN_ID} already exists."
else
  log "Creating vxlan${VXLAN_ID} → ${VXLAN_REMOTE_IP} via ${VXLAN_LOCAL_DEV}..."
  sudo ip link add vxlan${VXLAN_ID} type vxlan \
    id ${VXLAN_ID} remote ${VXLAN_REMOTE_IP} dstport ${VXLAN_DSTPORT} dev ${VXLAN_LOCAL_DEV}
  sudo ip link set vxlan${VXLAN_ID} master "${PROVISION_BRIDGE}" up
fi

# ---------------------------------------------------------------------------
# Persist via systemd-networkd
# ---------------------------------------------------------------------------
BR_NETDEV="/etc/systemd/network/10-${PROVISION_BRIDGE}.netdev"
BR_NETWORK="/etc/systemd/network/10-${PROVISION_BRIDGE}.network"
VX_NETDEV="/etc/systemd/network/20-vxlan${VXLAN_ID}.netdev"
VX_NETWORK="/etc/systemd/network/20-vxlan${VXLAN_ID}.network"

if [[ ! -f "${BR_NETDEV}" ]]; then
  log "Persisting bridge to ${BR_NETDEV}"
  sudo tee "${BR_NETDEV}" > /dev/null <<EOF
[NetDev]
Name=${PROVISION_BRIDGE}
Kind=bridge

[Bridge]
STP=no
EOF
fi

if [[ ! -f "${BR_NETWORK}" ]]; then
  log "Persisting bridge network to ${BR_NETWORK}"
  sudo tee "${BR_NETWORK}" > /dev/null <<EOF
[Match]
Name=${PROVISION_BRIDGE}

[Network]
ConfigureWithoutCarrier=yes
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF
fi

if [[ ! -f "${VX_NETDEV}" ]]; then
  log "Persisting vxlan${VXLAN_ID} to ${VX_NETDEV}"
  sudo tee "${VX_NETDEV}" > /dev/null <<EOF
[NetDev]
Name=vxlan${VXLAN_ID}
Kind=vxlan

[VXLAN]
VNI=${VXLAN_ID}
Remote=${VXLAN_REMOTE_IP}
Local=${VXLAN_LOCAL_IP}
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
# Verify
# ---------------------------------------------------------------------------
log "Interfaces:"
ip -br link show "${PROVISION_BRIDGE}" vxlan${VXLAN_ID}

log "Testing reachability to ${VXLAN_REMOTE_IP%.*}.1 (DGX Spark br-provision)..."
sudo ip addr add 172.22.0.99/24 dev "${PROVISION_BRIDGE}" 2>/dev/null || true
if ping -c 2 -W 2 172.22.0.1 > /dev/null 2>&1; then
  log "VXLAN tunnel verified."
else
  log "WARNING: ping 172.22.0.1 failed. Check that setup-vxlan.sh has been run on the DGX Spark."
fi
sudo ip addr del 172.22.0.99/24 dev "${PROVISION_BRIDGE}" 2>/dev/null || true
