#!/bin/bash
# prepare_extra_manifests.sh - Generate MachineConfig manifests from source files
#
# Regenerates the MachineConfig YAMLs from the butane source files,
# ensuring they stay aligned with the actual quadlet/registry content.
#
# Usage: prepare_extra_manifests.sh [output_dir]
#   output_dir: directory for generated manifests (default: script directory)
#
# Requires: butane

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKING_DIR="${WORKING_DIR:-/opt/dev-scripts}"
CLUSTER_NAME="${CLUSTER_NAME:-ostest}"
OUTPUT_DIR="${1:-${WORKING_DIR}/ocp/${CLUSTER_NAME}/openshift}"

if ! command -v butane &>/dev/null; then
    echo "ERROR: butane is required but not found. Install with: sudo dnf install butane"
    exit 1
fi

# Generate openperouter MachineConfig from quadlets
if [[ -f "${SCRIPTDIR}/openperouter-boot2.bu" ]]; then
    echo "Generating 99-master-openperouter.yaml from openperouter-boot2.bu"
    butane --files-dir="${SCRIPTDIR}" "${SCRIPTDIR}/openperouter-boot2.bu" \
        -o "${OUTPUT_DIR}/99-master-openperouter.yaml"
    echo "  -> ${OUTPUT_DIR}/99-master-openperouter.yaml"
fi

# Generate registry MachineConfig from registry sources
if [[ -f "${SCRIPTDIR}/registry-appliance.bu" ]]; then
    echo "Generating 01-master-registry.yaml from registry-appliance.bu"
    butane --files-dir="${SCRIPTDIR}" "${SCRIPTDIR}/registry-appliance.bu" \
        -o "${OUTPUT_DIR}/01-master-registry.yaml"
    echo "  -> ${OUTPUT_DIR}/01-master-registry.yaml"
fi

echo "Done. Generated manifests are in ${OUTPUT_DIR}"
