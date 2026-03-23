#!/bin/bash
# prepare_appliance.sh - Embed OpenPERouter files and registry mirrors
# into the appliance ISO ignition so they are available at first boot,
# before MachineConfig / MCO takes over.
#
# Usage: prepare_appliance.sh <appliance_iso> <ocp_dir>
#
# Requires: coreos-installer, jq, yq, base64

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

appliance_iso="$1"
ocp_dir="$2"

if [[ ! -f "${appliance_iso}" ]]; then
    echo "ERROR: Appliance ISO not found: ${appliance_iso}"
    exit 1
fi

# --- embed_files_in_appliance_iso ---
# Extracts the existing ignition from the ISO, merges additional files
# and systemd units, then re-embeds the modified ignition.
# Args: $1 = ISO path
#   Remaining args are either:
#     "source:dest:mode"       - file to embed
#     "unit-file:name:source"  - systemd unit from a file
embed_files_in_appliance_iso() {
    local iso_file="$1"
    shift

    local tmpdir
    tmpdir=$(mktemp -d)
    local orig_ign="${tmpdir}/original.ign"
    local merged_ign="${tmpdir}/merged.ign"

    sudo coreos-installer iso ignition show "${iso_file}" > "${orig_ign}" 2>/dev/null || echo '{"ignition":{"version":"3.4.0"}}' > "${orig_ign}"

    local files_json="[]"
    local units_json="[]"

    for entry in "$@"; do
        local prefix="${entry%%:*}"

        if [[ "${prefix}" == "unit-file" ]]; then
            local rest="${entry#unit-file:}"
            local unit_name="${rest%%:*}"
            local unit_src="${rest#*:}"
            if [[ ! -f "${unit_src}" ]]; then
                echo "WARNING: unit file ${unit_src} not found, skipping"
                continue
            fi
            local unit_contents
            unit_contents=$(cat "${unit_src}")
            units_json=$(echo "${units_json}" | jq --arg name "${unit_name}" \
                --arg contents "${unit_contents}" \
                '. + [{"name": $name, "enabled": true, "contents": $contents}]')
        else
            IFS=':' read -r src dest mode <<< "${entry}"
            if [[ ! -f "${src}" ]]; then
                echo "WARNING: ${src} not found, skipping"
                continue
            fi
            local encoded
            encoded=$(base64 -w0 < "${src}")
            files_json=$(echo "${files_json}" | jq --arg src "data:;base64,${encoded}" \
                --arg path "${dest}" --argjson mode "${mode}" \
                '. + [{"path": $path, "mode": $mode, "overwrite": true, "contents": {"source": $src}}]')
        fi
    done

    jq --argjson new_files "${files_json}" --argjson new_units "${units_json}" '
        .storage = (.storage // {}) |
        .storage.files = ((.storage.files // []) + $new_files) |
        if ($new_units | length) > 0 then
            .systemd = (.systemd // {}) |
            .systemd.units = ((.systemd.units // []) + $new_units)
        else . end
    ' "${orig_ign}" > "${merged_ign}"

    sudo coreos-installer iso ignition remove "${iso_file}" 2>/dev/null || true
    sudo coreos-installer iso ignition embed -i "${merged_ign}" "${iso_file}"

    rm -rf "${tmpdir}"
    echo "Embedded $(echo "${files_json}" | jq length) files and $(echo "${units_json}" | jq length) units into appliance ISO ignition"
}

# --- Generate registries.conf drop-in ---
# Converts IDMS/ITMS yaml files from the appliance cache into a
# registries.conf drop-in so mirror redirects work on first boot.
registries_conf="${ocp_dir}/appliance-registries.conf"
cluster_resources="${ocp_dir}/cache/"*"/cluster-resources"
{
    for yaml_file in ${cluster_resources}/idms-oc-mirror.yaml ${cluster_resources}/itms-oc-mirror.yaml; do
        if [[ ! -f "${yaml_file}" ]]; then
            continue
        fi
        if [[ "${yaml_file}" == *idms* ]]; then
            digest_only="true"
        else
            digest_only="false"
        fi
        yq -r '.spec.imageDigestMirrors // .spec.imageTagMirrors // [] | .[] | .source as $src | .mirrors[] | [$src, .] | @tsv' "${yaml_file}" | \
        while IFS=$'\t' read -r source mirror; do
            cat <<TOML

[[registry]]
  prefix = ""
  location = "${source}"
  mirror-by-digest-only = ${digest_only}

  [[registry.mirror]]
    location = "${mirror}"
    insecure = true
TOML
        done
    done
} > "${registries_conf}"

# --- Build embed arguments ---
embed_args=()

if [[ -s "${registries_conf}" ]]; then
    embed_args+=("${registries_conf}:/etc/containers/registries.conf.d/appliance-mirrors.conf:420")
fi

if [[ -d "${SCRIPTDIR}/quadlets" ]]; then
    embed_args+=(
        "${SCRIPTDIR}/quadlets/controllerpod.pod:/etc/containers/systemd/controllerpod.pod:420"
        "${SCRIPTDIR}/quadlets/controller.container:/etc/containers/systemd/controller.container:420"
        "${SCRIPTDIR}/quadlets/routerpod.pod:/etc/containers/systemd/routerpod.pod:420"
        "${SCRIPTDIR}/quadlets/frr.container:/etc/containers/systemd/frr.container:420"
        "${SCRIPTDIR}/quadlets/reloader.container:/etc/containers/systemd/reloader.container:420"
        "${SCRIPTDIR}/quadlets/frr-sockets.volume:/etc/containers/systemd/frr-sockets.volume:420"
        "${SCRIPTDIR}/quadlets/openperouter-node-index.sh:/usr/local/bin/openperouter-node-index.sh:493"
        "${SCRIPTDIR}/quadlets/openperouter-raw-config.sh:/usr/local/bin/openperouter-raw-config.sh:493"
        "${SCRIPTDIR}/quadlets/patch-installer-config.sh:/usr/local/bin/patch-installer-config.sh:493"
        "${SCRIPTDIR}/openpeconfig/node-config.yaml:/var/lib/openperouter/node-config.yaml:420"
        "${SCRIPTDIR}/openpeconfig/openpe_config.yaml:/var/lib/openperouter/configs/openpe_config.yaml:420"
        "unit-file:openperouter-node-index.service:${SCRIPTDIR}/quadlets/openperouter-node-index.service"
        "unit-file:openperouter-raw-config.service:${SCRIPTDIR}/quadlets/openperouter-raw-config.service"
        "unit-file:enable-virtual-interfaces.service:${SCRIPTDIR}/quadlets/enable-virtual-interfaces.service"
    )
fi

if [[ ${#embed_args[@]} -gt 0 ]]; then
    embed_files_in_appliance_iso "${appliance_iso}" "${embed_args[@]}"
else
    echo "Nothing to embed into appliance ISO"
fi

# --- Embed ignition hack script and service ---
if [[ -x "${SCRIPTDIR}/hackagent.sh" ]]; then
    "${SCRIPTDIR}/hackagent.sh" "${appliance_iso}"
fi
