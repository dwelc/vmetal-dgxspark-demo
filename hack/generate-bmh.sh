#!/usr/bin/env bash
# generate-bmh.sh — generate BareMetalHost YAML from VM inventory
#
# Creates per-host:
#   - BMC credentials Secret
#   - networkData Secret (static IP, gateway, DNS via config drive)
#   - BareMetalHost resource
#
# Uses PROVISION_IP (LAN IP of DGX Spark) for Redfish addresses so
# Ironic (running on a remote k3s node) can reach sushy-tools.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BMC_USERNAME="${BMC_USERNAME:-admin}"
BMC_PASSWORD="${BMC_PASSWORD:-password}"
PROVISION_IP="${PROVISION_IP:-192.168.1.101}"
PROVISION_CIDR="${PROVISION_CIDR:-172.22.0.0/24}"
PROVISION_GATEWAY="${PROVISION_GATEWAY:-172.22.0.1}"
PROVISION_DNS="${PROVISION_DNS:-172.22.0.1}"
SUSHY_PORT="${SUSHY_PORT:-8000}"
VM_IP_START="${VM_IP_START:-172.22.0.11}"

[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

INVENTORY_FILE="${REPO_ROOT}/configs/vm-inventory.txt"
[[ -f "${INVENTORY_FILE}" ]] || { echo "ERROR: ${INVENTORY_FILE} not found" >&2; exit 1; }

ip_prefix="${VM_IP_START%.*}"
ip_last="${VM_IP_START##*.}"
prefix_len="${PROVISION_CIDR##*/}"
ip_index=0

while read -r line; do
  [[ "${line}" =~ ^#.*$ || -z "${line}" ]] && continue
  read -r vm_name uuid mac profile <<< "${line}"

  vm_ip="${ip_prefix}.$((ip_last + ip_index))"
  ip_index=$((ip_index + 1))

  k8s_name="${vm_name}"
  secret_name="${k8s_name}-bmc-creds"
  network_secret_name="${k8s_name}-network-data"
  redfish_addr="redfish+http://${PROVISION_IP}:${SUSHY_PORT}/redfish/v1/Systems/${uuid}"

  cat <<EOF
---
# Secret: BMC credentials for ${vm_name}
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: metal3-system
type: Opaque
stringData:
  username: ${BMC_USERNAME}
  password: ${BMC_PASSWORD}
---
# Secret: networkData for ${vm_name} (config drive static network config)
# Provides static IP, default gateway, and DNS so the provisioned node
# has full network connectivity for container image pulls and cluster join.
apiVersion: v1
kind: Secret
metadata:
  name: ${network_secret_name}
  namespace: metal3-system
type: Opaque
stringData:
  networkData: |
    {
      "links": [
        {
          "id": "enp1s0",
          "type": "phy",
          "ethernet_mac_address": "${mac}"
        }
      ],
      "networks": [
        {
          "id": "provisioning",
          "link": "enp1s0",
          "type": "ipv4",
          "ip_address": "${vm_ip}",
          "netmask": "255.255.255.0",
          "routes": [
            {
              "network": "0.0.0.0",
              "netmask": "0.0.0.0",
              "gateway": "${PROVISION_GATEWAY}"
            }
          ]
        }
      ],
      "services": [
        {"type": "dns", "address": "${PROVISION_DNS}"}
      ]
    }
---
# BareMetalHost: ${vm_name} (profile: ${profile})
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${k8s_name}
  namespace: metal3-system
  labels:
    demo: vmetal
    vmetal-size: ${profile}
  annotations:
    metal3.vcluster.com/ip-address: "${vm_ip}/${prefix_len}"
    metal3.vcluster.com/gateway: "${PROVISION_GATEWAY}"
    metal3.vcluster.com/dns-servers: "${PROVISION_DNS}"
spec:
  online: true
  automatedCleaningMode: metadata
  bmc:
    address: ${redfish_addr}
    credentialsName: ${secret_name}
    disableCertificateVerification: true
  bootMACAddress: "${mac}"
  networkData:
    name: ${network_secret_name}
    namespace: metal3-system
  rootDeviceHints:
    deviceName: /dev/vda
EOF
done < "${INVENTORY_FILE}"
