# Recovery OTA rootfs and initramfs installation hooks

readonly OTA_ROOTFS_RUNTIME_DIR="usr/share/armbian-ota"

function ota_install_recovery_runtime_to_rootfs() {
    local root_dir="$1"

    ota_install_common_runtime_to_rootfs "${root_dir}" || return 1
    ota_sync_rootfs "Recovery OTA runtime" "${OTA_RECOVERY_ROOTFS}" "${root_dir}"
}

function ota_install_recovery_initramfs() {
    local root_dir="$1"
    local title="Recovery OTA initramfs"
    local -a initramfs_runtime_file_list=(
        "${OTA_ROOTFS_RUNTIME_DIR}/state.sh"
        "${OTA_ROOTFS_RUNTIME_DIR}/ota-log.sh"
        "${OTA_ROOTFS_RUNTIME_DIR}/ota-device.sh"
        "${OTA_ROOTFS_RUNTIME_DIR}/ota-payload.sh"
        "etc/initramfs-tools/hooks/99-copy-tools"
        "etc/initramfs-tools/scripts/init-premount/99-ota-apply"
        "etc/initramfs-tools/scripts/init-bottom/99-userdata-overlay"
    )
    local ota_runtime_file runtime_hash

    display_alert "${title}" "Preparing recovery OTA hooks for initramfs" "info"
    mkdir -p "${root_dir}/etc/initramfs-tools/conf.d"

    runtime_hash="$(
        {
            cd "${root_dir}" || exit 1
            for ota_runtime_file in "${initramfs_runtime_file_list[@]}"; do
                [[ -f "${ota_runtime_file}" ]] || continue
                sha256sum "${ota_runtime_file}"
            done
        } | sha256sum | awk '{print $1}'
    )" || {
        display_alert "${title}" "Failed to calculate initramfs cache stamp" "err"
        return 1
    }

    [[ -n "${runtime_hash}" ]] || {
        display_alert "${title}" "Empty initramfs cache stamp" "err"
        return 1
    }
    printf 'ARMBIAN_OTA_RUNTIME_HASH=%s\n' "${runtime_hash}" >"${root_dir}/etc/initramfs-tools/conf.d/armbian-ota-runtime.hash" || {
        display_alert "${title}" "Failed to write initramfs cache stamp" "err"
        return 1
    }
}

function pre_update_initramfs__894_install_recovery_ota_hooks() {
    if [[ "${OTA_ENABLE}" != "yes" || "${AB_PART_OTA}" == "yes" ]]; then
        return 0
    fi

    ota_install_recovery_runtime_to_rootfs "${MOUNT}" || return 1
    ota_install_recovery_initramfs "${MOUNT}"
}
