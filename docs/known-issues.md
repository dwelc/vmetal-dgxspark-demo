# Known Issues — arm64 / DGX Spark

Issues discovered while setting up vMetal on NVIDIA DGX Spark (Grace ARM CPU).

## 1. Metal3/Ironic container images — arm64-ready but CI only publishes amd64

**Images affected:**
- `quay.io/metal3-io/ironic:release-32.0`
- `quay.io/metal3-io/ironic-ipa-downloader:latest`
- `quay.io/metal3-io/baremetal-operator:v0.12.0`

**Impact:** Metal3/Ironic pods cannot run on the DGX Spark (arm64). They must
run on an x86 node with a VXLAN tunnel to the provisioning network.

**Details:** Metal3 officially supports aarch64 (see FAQ). The Dockerfiles are
fully multi-arch aware (`TARGETARCH`, arch-specific package lists, cross-compiled
iPXE/EFI for both architectures). The shared CI workflow in `metal3-io/project-infra`
has `multiPlatform` and `platform` inputs wired up for multi-arch builds — but no
caller currently enables them. The CI only builds and publishes amd64 images.

An x86 Ironic image CAN provision arm64 target nodes out of the box (iPXE and
EFI bootloaders for arm64 are baked into every build). The gap is running the
control plane itself on arm64.

**Upstream action:** Enable `multiPlatform: true` in the metal3-io CI workflows.
The Dockerfiles and shared infra are ready — it's a one-line change per repo.

## 2. vcluster-platform-dhcp-server arm64 image is mislabeled

**Image:** `ghcr.io/loft-sh/vcluster-platform-dhcp-server:0.5.0`

**Problem:** The OCI manifest advertises `linux/arm64`, and containerd pulls the
arm64 variant. However, the `/server` binary inside is compiled for x86-64.

**Evidence:**
```
$ crictl inspecti ... → architecture: "arm64"
$ ctr images mount ... && file /server → ELF 64-bit LSB executable, x86-64
```

**Impact:** `exec format error` on arm64 nodes. The DHCP proxy cannot run on DGX Spark.

**Action:** Report to Loft engineering. The arm64 build pipeline is copying the
amd64 binary into the arm64 image layers.

## 3. No upstream arm64 IPA ramdisk

**Problem:** The IPA ramdisk downloader (`ironic-ipa-downloader`) downloads x86
CentOS images from `tarballs.opendev.org`. No arm64 builds are published despite
CI jobs existing in `ironic-python-agent-builder`.

**Workaround:** Build arm64 IPA locally on the DGX Spark:
```bash
bash scripts/build-ipa-arm64.sh
```

This creates a tarball (`ipa-arm64.tar.gz`) served by the DGX Spark's image server.
The IPA downloader init container is patched with `IPA_BASEURI` and `IPA_FILENAME`
env vars (see README step 12) so it fetches the arm64 tarball automatically on
every metal3 pod restart. No manual intervention needed after the initial setup.

## 4. DHCP proxy TFTP incompatible with AAVMF UEFI PXE

**Problem:** The DHCP proxy's Go TFTP server uses option negotiation that the
AAVMF UEFI firmware PXE client doesn't handle correctly. The UEFI client sends
`tsize=0 blksize=1468 windowsize=4` and the server responds with an OACK that
causes the client to abort at block 0 ("User aborted the transfer").

**Workaround:** Run dnsmasq on the DGX Spark as a ProxyDHCP server that overrides
the TFTP server address to the DGX host, where dnsmasq serves iPXE via standard TFTP.

## 5. VMs require Secure Boot disabled

**Problem:** DGX Spark VMs default to AAVMF with Secure Boot and enrolled keys.
The IPA ramdisk kernel is unsigned, so Secure Boot blocks PXE boot.

**Workaround:** `create-vms.sh` automatically disables secure boot by switching
to `AAVMF_CODE.no-secboot.fd` firmware.

## 6. Cilium cni-exclusive removes Multus CNI config

**Problem:** Cilium's `cni-exclusive: "true"` setting (default) renames the Multus
CNI config to `*.cilium_bak`, preventing Multus from working.

**Fix:** Set `cni-exclusive: "false"` in Cilium config. If managed by ArgoCD,
update the Helm values and sync.

## 7. Cilium devices config for DGX Spark NIC

**Problem:** Cilium's `devices` config is typically set to a specific NIC name
(e.g., `enp2s0`). The DGX Spark has `enP7s7` (capital P, different naming).
Cilium fails to start with "unable to determine direct routing device."

**Fix:** Add the DGX Spark's NIC to the Cilium devices list:
```yaml
devices: "enp2s0 enP7s7"
```

## 8. Cilium BPF compilation fails with stale interfaces

**Problem:** If the DGX Spark previously had flannel/cni0 interfaces (from a prior
kubeadm setup), Cilium's BPF compiler fails with macro redefinition errors
(`ENABLE_ARP_RESPONDER`, `MONITOR_AGGREGATION`).

**Fix:** Remove stale interfaces before joining k3s:
```bash
sudo ip link delete flannel.1 cni0 2>/dev/null
sudo rm -rf /var/lib/cilium/bpf /var/run/cilium/state
```

## 9. /dev/kvm permissions on DGX Spark

**Problem:** After package updates or k3s install, `/dev/kvm` ownership changes
from `root:kvm` to `root:systemd-resolve`, preventing libvirt from starting VMs.

**Fix:** `bootstrap-dgx.sh` installs a udev rule to persist correct permissions:
```
SUBSYSTEM=="misc", KERNEL=="kvm", GROUP="kvm", MODE="0660"
```

## 10. 172.22.0.2 IP conflict

**Problem:** If the DGX Spark has 172.22.0.2 as a secondary IP on br-provision,
HTTP/TFTP traffic to the DHCP proxy container (also 172.22.0.2 via Multus) gets
delivered locally to the host instead of through the VXLAN to the container.

**Fix:** Do NOT add 172.22.0.2 to the DGX Spark's br-provision. Only 172.22.0.1.

## 11. Provisioned nodes have no DNS without networkData

**Problem:** The vCP DHCP proxy serves IP addresses but not gateway or DNS
DHCP options. Provisioned nodes boot with an IP but no default gateway, no DNS,
and no internet access. Container image pulls (flannel, etc.) fail with
"TLS handshake timeout" because DNS can't resolve registry hostnames.

**Fix:** Each BareMetalHost needs a `spec.networkData` reference pointing at a
Secret containing OpenStack-format network_data.json with static IP, gateway,
and DNS. The `generate-bmh.sh` script creates these automatically. DNS is set
to `172.22.0.1` (dnsmasq on the DGX Spark) which forwards to upstream resolvers.

## 12. TLS handshake timeout on container image pulls (MSS clamping)

**Problem:** Even with NAT and DNS working, HTTPS connections to container
registries fail with "TLS handshake timeout." The TCP connection establishes
but the TLS handshake (which involves large certificate packets) fails because
packets exceed the path MTU and get silently dropped.

**Fix:** TCP MSS clamping on the DGX Spark's FORWARD chain:
```bash
iptables -t mangle -A FORWARD -o enP7s7 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```
This is added automatically by `create-bridges.sh`.
