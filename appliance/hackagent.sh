#!/bin/bash

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <rhcos-iso-path> [output-iso-path]"
    exit 1
fi

ISO_PATH="$1"
OUTPUT_ISO="${2:-$1}"
WORK_DIR=$(mktemp -d)
EXTRACTED_IGN="$WORK_DIR/extracted.ign"
MODIFIED_IGN="$WORK_DIR/modified.ign"
HACK_SCRIPT_FILE="$WORK_DIR/hack-script.sh"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Extracting ignition from ISO: $ISO_PATH"

if sudo coreos-installer iso ignition show "$ISO_PATH" > "$EXTRACTED_IGN" 2>/dev/null && [ -s "$EXTRACTED_IGN" ]; then
    echo "Extracted existing ignition configuration"
else
    echo "No existing ignition found. Aborting"
    exit 1
fi

# Write the hack script to a file to avoid quoting hell
cat > "$HACK_SCRIPT_FILE" << 'HACKSCRIPT_EOF'
#!/bin/bash

LOG_FILE="/tmp/ignition-hack.log"
URL="https://192.168.110.2:22623/config/master"
IGN_FILE="/tmp/master-mcs-server.ign"
LOCAL_IGN_DIR="/opt/install-dir"
CONVERTER_IMAGE="quay.io/mavazque/ign-converter:latest"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "Starting ignition hack script"

# Pull the ignition converter image
log "Pulling ignition converter image: $CONVERTER_IMAGE"
if podman pull "$CONVERTER_IMAGE" 2>&1 | tee -a "$LOG_FILE"; then
    log "Successfully pulled converter image"
else
    log "ERROR: Failed to pull converter image"
    exit 1
fi

# Wait for the local master ignition file to be created
log "Waiting for local master ignition file in $LOCAL_IGN_DIR..."
while true; do
    LOCAL_IGN_FILE=$(find "$LOCAL_IGN_DIR" -maxdepth 1 -name 'master-*.ign' -type f 2>/dev/null | head -1)

    if [ -n "$LOCAL_IGN_FILE" ]; then
        log "Found local ignition file: $LOCAL_IGN_FILE"
        break
    fi

    sleep 1
done

# Extract ignition version from local file
IGN_VERSION=$(jq -r '.ignition.version' "$LOCAL_IGN_FILE")
if [ -z "$IGN_VERSION" ] || [ "$IGN_VERSION" = "null" ]; then
    log "ERROR: Could not extract ignition version from $LOCAL_IGN_FILE"
    exit 1
fi
log "Ignition version from local file: $IGN_VERSION"

# Extract hostname file config from local ignition
HOSTNAME_CONFIG=$(jq '.storage.files[] | select(.path == "/etc/hostname")' "$LOCAL_IGN_FILE" 2>/dev/null)
if [ -z "$HOSTNAME_CONFIG" ] || [ "$HOSTNAME_CONFIG" = "null" ]; then
    log "WARNING: No /etc/hostname configuration found in local ignition file"
    HOSTNAME_CONFIG=""
else
    log "Found hostname configuration in local ignition file"
fi

# Poll URL until MCS is accessible
log "Waiting for $URL to become accessible..."
while true; do
    if curl -k -s --connect-timeout 1 --max-time 5 -o "$IGN_FILE" "$URL"; then
        log "URL is accessible, saved ignition file to $IGN_FILE"
        break
    fi
    sleep 1
done

# Convert downloaded ignition from v2 to v3
log "Converting downloaded ignition file to spec v3..."
if podman run --privileged --rm -v /tmp:/tmp "$CONVERTER_IMAGE" -input "/tmp/master-mcs-server.ign" -output "/tmp/master-mcs-server-v3.ign" 2>&1 | tee -a "$LOG_FILE"; then
    mv /tmp/master-mcs-server-v3.ign /tmp/master-mcs-server.ign
    log "Successfully converted ignition to v3"
else
    log "ERROR: Failed to convert ignition file to v3"
    exit 1
fi

# Merge the hostname config and update version in downloaded ignition
log "Merging hostname config and updating ignition version..."
if [ -n "$HOSTNAME_CONFIG" ]; then
    jq --argjson hostname "$HOSTNAME_CONFIG" --arg version "$IGN_VERSION" '
        .ignition.version = $version |
        .storage.files = (
            [.storage.files[]? | select(.path != "/etc/hostname")] + [$hostname]
        )
    ' "$IGN_FILE" > "${IGN_FILE}.tmp" && mv "${IGN_FILE}.tmp" "$IGN_FILE"
else
    jq --arg version "$IGN_VERSION" '.ignition.version = $version' "$IGN_FILE" > "${IGN_FILE}.tmp" && mv "${IGN_FILE}.tmp" "$IGN_FILE"
fi

if [ $? -ne 0 ]; then
    log "ERROR: Failed to merge ignition configurations"
    exit 1
fi
log "Successfully merged ignition configuration"

# Extract arguments from journalctl, retry every 5 seconds until found
log "Extracting coreos-installer arguments from journalctl..."
while true; do
    ARGS=$(journalctl -b | grep 'Writing image and ignition to disk with arguments' | tail -1 | grep -oP 'Writing image and ignition to disk with arguments: \[\K[^\]]+')

    if [ -n "$ARGS" ]; then
        log "Found installer arguments"
        break
    fi

    log "Log line not found, retrying in 5 seconds..."
    sleep 5
done

log "Original arguments: $ARGS"

DISK=$(echo "$ARGS" | grep -oP '/dev/\S+')
log "Target disk: $DISK"

TRANSFORMED_ARGS=$(echo "$ARGS" | sed 's|-i [^ ]*|-i /tmp/master-mcs-server.ign|')
TRANSFORMED_ARGS=$(echo "$TRANSFORMED_ARGS" | sed 's/^install //')

COREOS_CMD="coreos-installer install $TRANSFORMED_ARGS"
log "Transformed command: $COREOS_CMD"

log "Backing up /etc/resolv.conf to /tmp/resolv.conf.bk"
cp /etc/resolv.conf /tmp/resolv.conf.bk

log "Writing nameserver to /etc/resolv.conf"
echo 'nameserver 169.254.0.1' > /etc/resolv.conf

log "Wiping filesystem signatures from $DISK"
wipefs -a "$DISK" -f 2>&1 | tee -a "$LOG_FILE"

log "Running: $COREOS_CMD"
$COREOS_CMD 2>&1 | tee -a "$LOG_FILE"
RESULT=${PIPESTATUS[0]}

log "Restoring /etc/resolv.conf from backup"
cp /tmp/resolv.conf.bk /etc/resolv.conf

if [ $RESULT -eq 0 ]; then
    log "coreos-installer completed successfully"
else
    log "ERROR: coreos-installer failed with exit code $RESULT"
    exit $RESULT
fi

log "Ignition hack script completed"
HACKSCRIPT_EOF

# Base64 encode the script (use printf to avoid trailing newline)
SCRIPT_B64=$(base64 -w0 < "$HACK_SCRIPT_FILE")

# Systemd unit file
SYSTEMD_UNIT='[Unit]
Description=Ignition Hack Script
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ignition-hack.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
'

# Merge into existing ignition
echo "Merging script and systemd unit into ignition..."
jq --arg script_b64 "$SCRIPT_B64" --arg unit "$SYSTEMD_UNIT" '
    .storage = (.storage // {}) |
    .storage.files = ((.storage.files // []) + [{
        "group": {},
        "overwrite": true,
        "path": "/usr/local/bin/ignition-hack.sh",
        "user": {
          "name": "root"
        },
        "mode": 365,
        "contents": {
            "source": ("data:text/plain;charset=utf-8;base64," + $script_b64),
            "verification": {}
        }
    }]) |
    .systemd = (.systemd // {}) |
    .systemd.units = ((.systemd.units // []) + [{
        "name": "ignition-hack.service",
        "enabled": true,
        "contents": $unit
    }])
' "$EXTRACTED_IGN" > "$MODIFIED_IGN"

echo "--- Generated merged ignition ---"

if [ "$OUTPUT_ISO" != "$ISO_PATH" ]; then
    echo "Copying ISO to: $OUTPUT_ISO"
    cp "$ISO_PATH" "$OUTPUT_ISO"
fi

echo "Removing any existing embedded ignition..."
sudo coreos-installer iso ignition remove "$OUTPUT_ISO" 2>/dev/null || true

echo "Embedding modified ignition into ISO..."
sudo coreos-installer iso ignition embed -i "$MODIFIED_IGN" "$OUTPUT_ISO"

echo "Done! Modified ISO: $OUTPUT_ISO"
