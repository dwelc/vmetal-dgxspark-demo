# vMetal DGX Spark Demo

Bare metal provisioning with vCluster Platform on NVIDIA DGX Spark (arm64).

Metal3/Ironic runs on an existing x86 k3s cluster. libvirt VMs on the DGX Spark
simulate bare metal nodes. A VXLAN tunnel bridges the provisioning network between
the two hosts. See [docs/architecture.md](docs/architecture.md) for details.

## Prerequisites

- **x86 k3s cluster** with vCluster Platform installed (Scale tier license)
- **NVIDIA DGX Spark** (or any arm64 host with KVM) on the same LAN
- SSH access to both the DGX Spark and one k3s node
- `kubectl` configured with the k3s cluster context

## Quick Start

### 1. Configure

```bash
cp configs/.env.example .env
# Edit .env — set LAN_IP, K3S_TOKEN, and adjust VM profiles
```

### 2. Bootstrap the DGX Spark

```bash
bash scripts/bootstrap-dgx.sh
# Log out and back in for group membership
```

### 3. Create provisioning bridge and VMs

```bash
bash scripts/create-bridges.sh
bash scripts/create-vms.sh
```

### 4. Install sushy-tools

```bash
bash scripts/install-sushy-service.sh
# Verify: curl http://192.168.1.101:8000/redfish/v1/Systems/
```

### 5. Build arm64 IPA ramdisk

No pre-built arm64 IPA exists upstream. Build it locally (~3 minutes).
This also creates a tarball that the IPA downloader init container will
fetch automatically on every metal3 pod restart.

```bash
bash scripts/build-ipa-arm64.sh
```

### 6. Set up ProxyDHCP + TFTP

The DHCP proxy's built-in TFTP is incompatible with AAVMF UEFI PXE.
This sets up dnsmasq as ProxyDHCP + TFTP with a locally-built arm64 iPXE:

```bash
bash scripts/setup-tftp.sh
```

### 7. Cache OS image (optional)

The OSImage manifest points at the public Ubuntu cloud image URL by default.
The provisioned host downloads it during provisioning via NAT through the DGX Spark.

For faster provisioning or air-gapped environments, cache it locally:

```bash
bash scripts/cache-os-image.sh
# Then update manifests/platform/os-image.yaml to use the local URL:
#   http://172.22.0.1:9000/ubuntu-24.04-minimal-cloudimg-arm64.img
```

### 8. Join DGX Spark to k3s cluster

```bash
curl -sfL https://get.k3s.io | \
  K3S_URL=https://192.168.1.102:6443 \
  K3S_TOKEN=<your-token> sh -
```

Label and taint it:

```bash
kubectl label node dgx-spark-1 node-role.kubernetes.io/vmetal=true
kubectl taint node dgx-spark-1 vmetal=true:NoSchedule
```

### 9. Set up VXLAN tunnel

Both ends are persisted via systemd-networkd so the tunnel survives reboots.

On the DGX Spark:

```bash
bash scripts/setup-vxlan.sh
```

Then on the k3s node (dan-dev-1):

```bash
bash scripts/setup-vxlan-k3s.sh
```

The k3s script creates `br-provision` + `vxlan100`, writes
`/etc/systemd/network/{10-br-provision,20-vxlan100}.{netdev,network}`,
and ping-tests `172.22.0.1` at the end.

Also install CNI plugins on dan-dev-1 (needed for Multus secondary interfaces):

```bash
# On dan-dev-1:
CNI_VERSION=v1.4.0
curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" \
  | sudo tar xz -C /opt/cni/bin/
```

### 10. Cluster configuration changes

These changes are needed in your cluster (update via ArgoCD or directly):

**Cilium** — add DGX Spark NIC and disable exclusive CNI:
```yaml
devices: "enp2s0 enP7s7"
cni-exclusive: "false"     # required for Multus
```

**Longhorn** — tolerate the vmetal taint:
```yaml
longhornManager:
  tolerations:
    - key: vmetal
      operator: Equal
      value: "true"
      effect: NoSchedule
longhornDriver:
  tolerations:
    - key: vmetal
      operator: Equal
      value: "true"
      effect: NoSchedule
```

### 11. Apply platform manifests

```bash
kubectl apply -f manifests/platform/node-provider.yaml
kubectl apply -f manifests/platform/os-image.yaml
kubectl apply -f manifests/network/metal3-provision-nad.yaml
```

### 12. Patch Metal3 StatefulSets

The NodeProvider helmValues handle `nodeSelector`. These remaining patches
are needed for settings the Helm chart doesn't expose:

```bash
# fsGroup for Ironic DB permissions, HTTP port, Multus provisioning interface
kubectl patch statefulset -n metal3-system metal3 --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/securityContext","value":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"},"fsGroup":994}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"HTTP_PORT","value":"6180"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"PROVISIONING_INTERFACE","value":"net1"}}
]'

# Multus annotation so Ironic gets an interface on br-provision
kubectl patch statefulset -n metal3-system metal3 --type='strategic' \
  -p='{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"metal3-system/metal3-provision"}}}}}'

# IPA downloader: fetch arm64 IPA tarball from DGX Spark image server
# instead of the default x86 CentOS IPA from upstream.
# This is the key patch that makes arm64 IPA persist across pod restarts.
kubectl patch statefulset -n metal3-system metal3 --type='json' -p='[
  {"op":"add","path":"/spec/template/spec/initContainers/0/env","value":[
    {"name":"IPA_BASEURI","value":"http://172.22.0.1:9000"},
    {"name":"IPA_FILENAME","value":"ipa-arm64.tar.gz"}
  ]}
]'

# Restart pods to pick up changes
kubectl delete pod -n metal3-system metal3-0 dhcp-proxy-0
```

These patches survive pod restarts (they're on the StatefulSet spec).
They only need to be re-applied if the NodeProvider controller recreates
the StatefulSets (e.g. after re-applying node-provider.yaml).

### 13. Restore Multus CNI config (if Cilium removed it)

On dan-dev-1, check if Multus config exists:

```bash
sudo ls /etc/cni/net.d/00-multus.conf
# If missing:
sudo cp /etc/cni/net.d/00-multus.conf.cilium_bak /etc/cni/net.d/00-multus.conf
```

### 14. Register BareMetalHosts

```bash
bash hack/generate-bmh.sh | kubectl apply -f -
```

Watch inspection progress:

```bash
kubectl get baremetalhosts -n metal3-system -w
```

All hosts should reach `available` state within 3-5 minutes. The flow is:
`registering` -> `inspecting` (VMs PXE boot, IPA runs, reports back) -> `available`.

### 15. Create vCluster (triggers provisioning)

```bash
kubectl apply -f manifests/platform/vmetal-template.yaml
kubectl apply -f manifests/platform/vcluster-vmetal.yaml
```

Watch:

```bash
kubectl get virtualclusterinstances -n p-default
kubectl get nodeclaims -A -w
kubectl get baremetalhosts -n metal3-system -w
```

## Troubleshooting

If the IPA downloader patch isn't working (e.g. chart version doesn't
support init container env vars), use the manual copy script:

```bash
bash hack/copy-ipa-to-ironic.sh
```

This must be re-run after every metal3-0 pod restart.

## Known Issues

See [docs/known-issues.md](docs/known-issues.md) for arm64-specific issues
including CI-only amd64 builds, missing upstream IPA, TFTP incompatibilities,
and required workarounds.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the multi-host setup,
VXLAN tunnel design, PXE boot flow, and IP allocation.
