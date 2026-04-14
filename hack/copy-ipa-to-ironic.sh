#!/usr/bin/env bash
# copy-ipa-to-ironic.sh — TROUBLESHOOTING: manually copy arm64 IPA files
#
# Normally, the IPA downloader init container is patched with IPA_BASEURI
# and IPA_FILENAME env vars (see README step 12) so it fetches the arm64
# tarball automatically. This script is a FALLBACK for when that patch
# isn't working or hasn't been applied yet.
#
# Usage:
#   bash hack/copy-ipa-to-ironic.sh [kubectl-context]

set -euo pipefail

CONTEXT="${1:-homelab}"
NAMESPACE="metal3-system"
POD="metal3-0"
CONTAINER="ironic"
DGX_HOST="${DGX_HOST:-dgx-spark-1}"

IPA_KERNEL="/srv/os-images/ipa-arm64.kernel"
IPA_INITRAMFS="/srv/os-images/ipa-arm64.initramfs"

log() { echo "[copy-ipa] $*"; }

# ---------------------------------------------------------------------------
# Wait for metal3-0 to be ready
# ---------------------------------------------------------------------------
log "Waiting for ${POD} to be ready..."
while true; do
  ready=$(kubectl --context "${CONTEXT}" get pod -n "${NAMESPACE}" "${POD}" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="ironic")].ready}' 2>/dev/null)
  if [[ "${ready}" == "true" ]]; then break; fi
  sleep 2
done
log "${POD} is ready."

# ---------------------------------------------------------------------------
# Remove default x86 symlinks and copy arm64 files
# ---------------------------------------------------------------------------
log "Removing default x86 IPA symlinks..."
kubectl --context "${CONTEXT}" exec -n "${NAMESPACE}" "${POD}" -c "${CONTAINER}" -- \
  rm -f /shared/html/images/ironic-python-agent.kernel \
       /shared/html/images/ironic-python-agent.initramfs

log "Copying arm64 IPA kernel..."
ssh "${DGX_HOST}" "cat ${IPA_KERNEL}" | \
  kubectl --context "${CONTEXT}" exec -i -n "${NAMESPACE}" "${POD}" -c "${CONTAINER}" -- \
  tee /shared/html/images/ironic-python-agent.kernel > /dev/null

log "Copying arm64 IPA initramfs (~300MB)..."
ssh "${DGX_HOST}" "cat ${IPA_INITRAMFS}" | \
  kubectl --context "${CONTEXT}" exec -i -n "${NAMESPACE}" "${POD}" -c "${CONTAINER}" -- \
  tee /shared/html/images/ironic-python-agent.initramfs > /dev/null

log "Verifying..."
kubectl --context "${CONTEXT}" exec -n "${NAMESPACE}" "${POD}" -c "${CONTAINER}" -- \
  ls -lh /shared/html/images/ironic-python-agent.kernel \
         /shared/html/images/ironic-python-agent.initramfs

echo ""
echo "====================================================================="
echo " arm64 IPA files copied to ${POD}."
echo " These are regular files (not symlinks) so the IPA downloader"
echo " won't overwrite them during this pod's lifetime."
echo ""
echo " WARNING: You must re-run this script after every metal3-0 restart."
echo "====================================================================="
