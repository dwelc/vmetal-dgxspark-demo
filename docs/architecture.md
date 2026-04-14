# Architecture

## Multi-host setup

This demo runs across two types of hosts connected to the same flat LAN:

```
k3s cluster (x86)                              DGX Spark (arm64)
192.168.1.102-104                              192.168.1.101
┌──────────────────────────────┐               ┌──────────────────────────────┐
│  dan-dev-1 (192.168.1.102)   │               │  dgx-spark-1                 │
│  ┌────────────────────────┐  │               │  ┌────────────────────────┐  │
│  │  br-provision (no IP)  │  │               │  │  br-provision          │  │
│  │    │                   │  │               │  │  172.22.0.1/24         │  │
│  │    └── vxlan100 ───────┼──┼── LAN ────────┼──┼── vxlan100            │  │
│  │                        │  │  (VXLAN)      │  │    │                   │  │
│  │  metal3-0 (Ironic)     │  │               │  │    ├── vmetal-small-1  │  │
│  │    172.22.0.3 (Multus) │  │               │  │    ├── vmetal-small-2  │  │
│  │  dhcp-proxy-0          │  │               │  │    ├── vmetal-small-3  │  │
│  │    172.22.0.2 (Multus) │  │               │  │    ├── vmetal-large-1  │  │
│  └────────────────────────┘  │               │  │    └── vmetal-large-2  │  │
│                              │               │  └────────────────────────┘  │
│  dan-dev-2, dan-dev-3        │               │                              │
│  (other k3s control plane)   │               │  sushy-tools    :8000        │
│                              │               │  dnsmasq TFTP   :69          │
│  vCluster Platform           │               │  dnsmasq DNS    :53          │
│  ArgoCD, Cilium, Longhorn    │               │  ProxyDHCP      :67          │
└──────────────────────────────┘               └──────────────────────────────┘
```

## Why this architecture

Metal3/Ironic container images are **amd64-only** (no arm64 builds). They must run
on the x86 k3s nodes. The DGX Spark's libvirt VMs are arm64 (host CPU architecture).

A VXLAN tunnel extends the provisioning bridge (`br-provision`) from the DGX Spark
to `dan-dev-1`, where the Metal3 pods are scheduled. Multus gives the pods secondary
network interfaces on `br-provision` so they can communicate with the VMs.

## PXE boot flow

1. Ironic powers on a VM via sushy-tools Redfish API (192.168.1.101:8000)
2. VM UEFI firmware does PXE boot → DHCP request on br-provision
3. DHCP proxy (172.22.0.2) responds with IP and boot filename
4. **DGX Spark dnsmasq** (ProxyDHCP on 172.22.0.1) overrides TFTP server to 172.22.0.1
5. VM downloads arm64 iPXE binary via TFTP from dnsmasq on 172.22.0.1
6. iPXE re-does DHCP, gets inspector.ipxe script URL from DHCP proxy
7. iPXE downloads boot script from DHCP proxy HTTP (172.22.0.2:8080)
8. iPXE downloads arm64 IPA kernel+initramfs from Ironic HTTPD (172.22.0.3:6180)
9. IPA boots, inspects hardware, calls back to Ironic (172.22.0.3:6385)
10. Ironic marks BareMetalHost as `available`

## Why ProxyDHCP

The DHCP proxy pod's built-in Go TFTP server has a TFTP option negotiation
incompatibility with the AAVMF UEFI firmware PXE client. The UEFI client
sends `tsize`, `blksize`, and `windowsize` options which the Go TFTP server
handles in a way that causes the transfer to abort at block 0.

Running dnsmasq on the DGX Spark as a ProxyDHCP server overrides the TFTP
server address from 172.22.0.2 (broken) to 172.22.0.1 (dnsmasq, works).

## Why arm64 IPA must be built locally

Upstream OpenStack does not publish pre-built arm64 IPA ramdisk images.
The CI jobs exist but artifacts aren't uploaded to tarballs.opendev.org.
The `build-ipa-arm64.sh` script builds one natively on the DGX Spark
using `ironic-python-agent-builder` with Debian Trixie.

## arm64 IPA persistence across pod restarts

The default IPA downloader init container downloads x86 CentOS IPA from
upstream on every pod restart, overwriting any arm64 files. To solve this:

1. `build-ipa-arm64.sh` creates a tarball (`ipa-arm64.tar.gz`) containing
   the arm64 kernel and initramfs, served by the DGX Spark's image server.
2. The IPA downloader init container is patched with env vars:
   - `IPA_BASEURI=http://172.22.0.1:9000`
   - `IPA_FILENAME=ipa-arm64.tar.gz`
3. On every metal3 pod restart, the init container fetches the arm64
   tarball from the local image server instead of the upstream x86 one.

The tarball format follows the IPA downloader's convention: it contains
`ipa-arm64.kernel` and `ipa-arm64.initramfs`, which get symlinked to
the standard `ironic-python-agent.kernel` and `.initramfs` names.

## IP address allocation

| IP | Used by |
|----|---------|
| 172.22.0.1 | DGX Spark br-provision, dnsmasq (TFTP + ProxyDHCP + DNS forwarder), IPA tarball server |
| 172.22.0.2 | DHCP proxy pod (Multus) |
| 172.22.0.3 | Ironic/metal3 pod (Multus) |
| 172.22.0.11-15 | VMs (assigned by DHCP proxy) |

## Provisioned node networking

After Ironic writes the OS image to disk, the provisioned node boots Ubuntu.
Network configuration comes from two sources:

1. **Config drive (networkData Secret)** — Static IP, gateway (`172.22.0.1`),
   and DNS (`172.22.0.1`) written by Ironic. Cloud-init reads this on first boot
   and generates netplan config. This is the primary network configuration.

2. **DHCP proxy** — Assigns an IP during PXE boot and IPA inspection. After the
   OS is installed, the config drive's static config takes precedence.

Outbound internet access for the provisioned node (needed for container image
pulls) works via:

- **Default gateway** `172.22.0.1` (DGX Spark bridge IP)
- **NAT masquerade** on the DGX Spark (iptables POSTROUTING rule)
- **TCP MSS clamping** on the DGX Spark (iptables mangle rule) — required to
  prevent TLS handshake timeouts due to path MTU issues
- **DNS forwarding** via dnsmasq on `172.22.0.1:53` → upstream `8.8.8.8`/`1.1.1.1`
