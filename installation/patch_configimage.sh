#!/usr/bin/env bash
set -euxo pipefail

# Patch the config-image ISO to inject ENABLE_VIRTUAL_INTERFACES=true
# into the assisted-service environment.
#
# This must run AFTER "openshift-install agent create config-image".
#
# The config-image ISO contains CONFIG.GZ — a gzipped cpio archive with
# the cluster-specific files. We extract it, modify assisted-service.env,
# and rebuild the ISO.

CLUSTER_NAME="${CLUSTER_NAME:-ostest}"
OCP_DIR="${OCP_DIR:-ocp/${CLUSTER_NAME}}"
CONFIG_IMAGE_DIR="$(realpath "${OCP_DIR}/configimage")"
CONFIG_IMAGE_ISO="${CONFIG_IMAGE_DIR}/agentconfig.noarch.iso"

if [ ! -f "${CONFIG_IMAGE_ISO}" ]; then
  echo "ERROR: ${CONFIG_IMAGE_ISO} not found. Run 'openshift-install agent create config-image' first."
  exit 1
fi

TMPDIR=$(mktemp -d)
trap "sudo rm -rf ${TMPDIR}" EXIT

# ── Extract the cpio archive from the ISO ─────────────────────────────────────

isoinfo -i "${CONFIG_IMAGE_ISO}" -x "/CONFIG.GZ;1" | gunzip > "${TMPDIR}/config.cpio"

mkdir -p "${TMPDIR}/root"
cd "${TMPDIR}/root"
sudo cpio -idm --no-absolute-filenames < "${TMPDIR}/config.cpio"

# ── Modify assisted-service.env ───────────────────────────────────────────────

ENV_FILE="${TMPDIR}/root/usr/local/share/assisted-service/assisted-service.env"
if ! sudo test -f "${ENV_FILE}"; then
  echo "ERROR: assisted-service.env not found in config-image"
  exit 1
fi

if ! sudo grep -q "^ENABLE_VIRTUAL_INTERFACES=" "${ENV_FILE}"; then
  echo "ENABLE_VIRTUAL_INTERFACES=true" | sudo tee -a "${ENV_FILE}" > /dev/null
  echo "Injected ENABLE_VIRTUAL_INTERFACES=true into assisted-service.env"
else
  echo "ENABLE_VIRTUAL_INTERFACES already set"
fi

# The agent's connectivity checker (assisted-installer-agent/src/connectivity_check/util.go)
# only uses physical, bonding, or VLAN interfaces for outgoing L2 checks — bridge
# interfaces are explicitly excluded. When the machine network IP lives on br0,
# arping is never performed on that subnet, so "belongs-to-majority-group" always
# fails. ENABLE_VIRTUAL_INTERFACES only affects inventory reporting on the
# assisted-service side, not the agent-side connectivity checker. Until the agent
# is patched to support bridge interfaces, we must disable this validation.
if ! sudo grep -q "^DISABLED_HOST_VALIDATIONS=" "${ENV_FILE}"; then
  echo "DISABLED_HOST_VALIDATIONS=belongs-to-majority-group" | sudo tee -a "${ENV_FILE}" > /dev/null
  echo "Injected DISABLED_HOST_VALIDATIONS=belongs-to-majority-group into assisted-service.env"
else
  echo "DISABLED_HOST_VALIDATIONS already set"
fi

# ── Rebuild cpio archive with absolute paths ──────────────────────────────────

# The original archive uses absolute paths. We chroot into the extracted tree
# so cpio resolves absolute filenames correctly. Copy the dynamic linker and
# libraries so the dynamically-linked cpio binary works inside the chroot.

LDSO=$(readelf -l /usr/bin/cpio 2>/dev/null | grep 'interpreter' | sed 's/.*: \(.*\)]/\1/')
sudo cp /usr/bin/cpio "${TMPDIR}/root/.cpio"
sudo cp "${LDSO}" "${TMPDIR}/root/.ld.so"
sudo mkdir -p "${TMPDIR}/root/.libs"
ldd /usr/bin/cpio | awk '/=>/{print $3}' | while read lib; do
    sudo cp "$lib" "${TMPDIR}/root/.libs/"
done

cd "${TMPDIR}/root"
sudo find . -mindepth 1 -not -name '.cpio' -not -name '.ld.so' -not -path './.libs*' \
    | sed 's|^\./|/|' \
    | sudo chroot "${TMPDIR}/root" /.ld.so --library-path /.libs /.cpio -o -H newc \
    > "${TMPDIR}/config-new.cpio"

sudo rm -f "${TMPDIR}/root/.cpio" "${TMPDIR}/root/.ld.so"
sudo rm -rf "${TMPDIR}/root/.libs"

# ── Rebuild the ISO ───────────────────────────────────────────────────────────

mkdir -p "${TMPDIR}/iso"
gzip -c "${TMPDIR}/config-new.cpio" > "${TMPDIR}/iso/config.gz"
mkisofs -o "${CONFIG_IMAGE_ISO}" -V "agent_configimage" -r "${TMPDIR}/iso/"

echo "Patched ${CONFIG_IMAGE_ISO} with ENABLE_VIRTUAL_INTERFACES=true"
