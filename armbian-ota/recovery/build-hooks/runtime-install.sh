# Recovery OTA rootfs and initramfs installation hooks

readonly OTA_ROOTFS_RUNTIME_DIR="usr/share/armbian-ota"

function ota_install_recovery_runtime_to_rootfs() {
    local root_dir="$1"

    ota_install_common_runtime_to_rootfs "${root_dir}" || return 1
    ota_sync_rootfs "Recovery OTA runtime" "${OTA_RECOVERY_ROOTFS}" "${root_dir}"
}

function ota_install_recovery_initramfs_file() {
    local source="$1" destination="$2" mode="$3"

    [[ -f "${source}" ]] || {
        display_alert "Recovery OTA initramfs" "Missing source file: ${source}" "err"
        return 1
    }
    install -D -m "${mode}" "${source}" "${destination}" || {
        display_alert "Recovery OTA initramfs" "Failed to install: ${source}" "err"
        return 1
    }
}

function ota_install_recovery_initramfs() {
    local root_dir="$1"
    local title="Recovery OTA initramfs"
    local -a initramfs_file_list=(
        "hooks/99-copy-tools:etc/initramfs-tools/hooks/99-copy-tools:0755"
        "scripts/init-premount/99-ota-apply:etc/initramfs-tools/scripts/init-premount/99-ota-apply:0755"
        "recovery/log.sh:etc/initramfs-tools/ota/recovery/log.sh:0644"
        "recovery/device.sh:etc/initramfs-tools/ota/recovery/device.sh:0644"
        "recovery/payload.sh:etc/initramfs-tools/ota/recovery/payload.sh:0644"
    )
    local entry source_path destination_path mode runtime_hash

    display_alert "${title}" "Preparing recovery OTA hooks for initramfs" "info"
    mkdir -p "${root_dir}/etc/initramfs-tools/conf.d"
    for entry in "${initramfs_file_list[@]}"; do
        IFS=: read -r source_path destination_path mode <<< "${entry}"
        ota_install_recovery_initramfs_file \
            "${OTA_RECOVERY_INITRAMFS}/${source_path}" \
            "${root_dir}/${destination_path}" "${mode}" || return 1
    done

    runtime_hash="$(
        {
            cd "${root_dir}" || exit 1
            sha256sum "${OTA_ROOTFS_RUNTIME_DIR}/state.sh"
            for entry in "${initramfs_file_list[@]}"; do
                IFS=: read -r source_path destination_path mode <<< "${entry}"
                sha256sum "${destination_path}"
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
    ota_install_recovery_runtime_to_rootfs "${MOUNT}" || return 1
    ota_install_recovery_initramfs "${MOUNT}"
}
