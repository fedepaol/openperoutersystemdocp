#!/usr/bin/env bash
# Generate the per-node openpe_raw_config.yaml with the node's bridge IP
# announced via BGP in the red VRF.

set -euo pipefail

BRIDGE_NAME="${1:-br0}"
RAW_CONFIG_PATH="/var/lib/openperouter/configs/openpe_raw_config.yaml"
ASN="64514"
VRF="red"
MAX_RETRIES=60

get_bridge_ip() {
  ip -4 -o addr show dev "${BRIDGE_NAME}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true
}

# Wait for the bridge to get an IPv4 address
BRIDGE_IP=""
for (( i=1; i<=MAX_RETRIES; i++ )); do
  BRIDGE_IP=$(get_bridge_ip)
  if [ -n "${BRIDGE_IP}" ]; then
    break
  fi
  echo "Waiting for ${BRIDGE_NAME} to get an IPv4 address (attempt ${i}/${MAX_RETRIES})..."
  sleep 2
done

if [ -z "${BRIDGE_IP}" ]; then
  echo "ERROR: No IPv4 address found on ${BRIDGE_NAME} after ${MAX_RETRIES} attempts" >&2
  exit 1
fi

echo "Generating ${RAW_CONFIG_PATH} with network ${BRIDGE_IP}/32 (from ${BRIDGE_NAME})"

mkdir -p "$(dirname "${RAW_CONFIG_PATH}")"
cat > "${RAW_CONFIG_PATH}" <<EOF
rawfrrconfigs:
  - rawConfig: |
      router bgp ${ASN} vrf ${VRF}
        address-family ipv4 unicast
          network ${BRIDGE_IP}/32
        exit-address-family
      exit
EOF
