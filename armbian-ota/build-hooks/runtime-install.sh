# Internal OTA helper functions

readonly OTA_ROOTFS_SBIN_DIR="usr/sbin"
readonly OTA_ROOTFS_RUNTIME_DIR="usr/share/armbian-ota"
readonly OTA_ROOTFS_LIB_DIR="usr/lib/armbian"
readonly OTA_ROOTFS_SYSTEMD_DIR="etc/systemd/system"
readonly OTA_ROOTFS_CONFIG_DIR="etc/armbian-ota"

function ota_copy_file() {
    local title="${1:-ota_copy_file}"
    local source="$2"
    local target="$3"
    local failure_level="${4:-err}"
    local mode="${5:-0644}"

    install -D -m "${mode}" "${source}" "${target}" && return 0

    display_alert "${title}" "Failed to install ${target}" "${failure_level}"
    [[ "${failure_level}" == "err" ]] && return 1
    return 0
}

function ota_install_file_list() {
    local title="$1"
    local root_dir="$2"
    local file source target failure_level mode
    shift 2

    for file in "$@"; do
        IFS='|' read -r source target failure_level mode <<<"${file}"
        ota_copy_file "${title}" "${source}" "${root_dir}/${target}" \
            "${failure_level}" "${mode}" || return 1
    done
}

function ota_install_common_runtime_to_rootfs() {
    local root_dir="$1"
    local title="OTA runtime"
    local -a runtime_file_list=(
        "${OTA_RUNTIME_SRC}/bin/armbian-ota|${OTA_ROOTFS_SBIN_DIR}/armbian-ota|err|0755"
        "${OTA_RUNTIME_SRC}/lib/common.sh|${OTA_ROOTFS_RUNTIME_DIR}/common.sh|err|0644"
        "${OTA_RUNTIME_SRC}/lib/state.sh|${OTA_ROOTFS_RUNTIME_DIR}/state.sh|err|0644"
        "${OTA_RUNTIME_SRC}/lib/preserve.sh|${OTA_ROOTFS_RUNTIME_DIR}/preserve.sh|err|0644"
        "${OTA_RUNTIME_SRC}/policy/preserve-list.txt|${OTA_ROOTFS_CONFIG_DIR}/preserve-list.txt|err|0644"
    )

    display_alert "${title}" "Installing common OTA runtime into rootfs" "info"
    ota_install_file_list "${title}" "${root_dir}" "${runtime_file_list[@]}"
}

function ota_install_recovery_runtime_to_rootfs() {
    local root_dir="$1"
    local title="OTA runtime"
    local -a recovery_file_list=(
        "${OTA_RUNTIME_SRC}/lib/persist.sh|${OTA_ROOTFS_RUNTIME_DIR}/persist.sh|err|0644"
        "${OTA_RUNTIME_SRC}/policy/persist-map.txt|${OTA_ROOTFS_CONFIG_DIR}/persist-map.txt|warn|0644"
        "${OTA_RECOVERY_SRC}/backend.sh|${OTA_ROOTFS_RUNTIME_DIR}/backend-recovery.sh|err|0644"
    )

    if [[ ! -d "${OTA_RUNTIME_SRC}" ]]; then
        display_alert "${title}" "runtime source dir missing: ${OTA_RUNTIME_SRC}" "warn"
        return 0
    fi

    ota_install_common_runtime_to_rootfs "${root_dir}" || return 1

    display_alert "${title}" "Installing Recovery OTA runtime into rootfs" "info"
    ota_install_file_list "${title}" "${root_dir}" "${recovery_file_list[@]}"
}

function ota_install_recovery_initramfs() {
    local root_dir="$1"
    local title="Recovery OTA initramfs"
    local -a initramfs_hook_list=(
        "${OTA_RECOVERY_SRC}/initramfs_hooks/99-copy-tools|etc/initramfs-tools/hooks/99-copy-tools|err|0755"
        "${OTA_RECOVERY_SRC}/initramfs_hooks/99-ota-apply|etc/initramfs-tools/scripts/init-premount/99-ota-apply|err|0755"
    )
    local -a initramfs_runtime_file_list=(
        "${OTA_ROOTFS_RUNTIME_DIR}/state.sh"
        "${OTA_ROOTFS_RUNTIME_DIR}/persist.sh"
        "${OTA_ROOTFS_RUNTIME_DIR}/preserve.sh"
        "etc/initramfs-tools/hooks/99-copy-tools"
        "etc/initramfs-tools/scripts/init-premount/99-ota-apply"
    )
    local ota_runtime_file

    display_alert "${title}" "Installing recovery OTA hooks into target initramfs" "info"
    mkdir -p "${root_dir}/etc/initramfs-tools/conf.d"

    ota_install_file_list "${title}" "${root_dir}" "${initramfs_hook_list[@]}" || return 1

    local runtime_hash
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

    return 0
}

function ota_install_ab_runtime_to_rootfs() {
    local root_dir="$1"
    local title="OTA runtime"
    local -a ab_runtime_file_list=(
        "${OTA_RUNTIME_SRC}/lib/ab-env.sh|${OTA_ROOTFS_RUNTIME_DIR}/ab-env.sh|err|0644"
        "${OTA_AB_SRC}/backend.sh|${OTA_ROOTFS_RUNTIME_DIR}/backend-ab.sh|err|0644"
    )

    if [[ ! -d "${OTA_RUNTIME_SRC}" ]]; then
        display_alert "${title}" "runtime source dir missing: ${OTA_RUNTIME_SRC}" "warn"
        return 0
    fi

    ota_install_common_runtime_to_rootfs "${root_dir}" || return 1

    display_alert "${title}" "Installing A/B OTA runtime into rootfs" "info"
    ota_install_file_list "${title}" "${root_dir}" "${ab_runtime_file_list[@]}"
}

function ota_install_ab_tools_to_rootfs() {
    local root_dir="$1"
    local title="A/B partition OTA"
    local -a ab_tool_file_list=(
        "${OTA_AB_SRC}/lib/armbian-ota-health-check|${OTA_ROOTFS_LIB_DIR}/armbian-ota-health-check|err|0755"
        "${OTA_AB_SRC}/lib/armbian-ota-init-uboot|${OTA_ROOTFS_LIB_DIR}/armbian-ota-init-uboot|err|0755"
        "${OTA_AB_SRC}/systemd/armbian-ota-init-uboot.service|${OTA_ROOTFS_SYSTEMD_DIR}/armbian-ota-init-uboot.service|err|0644"
        "${OTA_AB_SRC}/systemd/armbian-ota-firstboot.service|${OTA_ROOTFS_SYSTEMD_DIR}/armbian-ota-firstboot.service|err|0644"
        "${OTA_AB_SRC}/systemd/armbian-ota-rollback.service|${OTA_ROOTFS_SYSTEMD_DIR}/armbian-ota-rollback.service|err|0644"
    )

    display_alert "${title}" "Installing AB OTA userspace tools" "info"
    ota_install_file_list "${title}" "${root_dir}" "${ab_tool_file_list[@]}" || return 1

    chroot "${root_dir}" systemctl enable armbian-ota-init-uboot.service \
        || display_alert "${title}" "Failed to enable armbian-ota-init-uboot.service" "warn"
    chroot "${root_dir}" systemctl enable armbian-ota-firstboot.service \
        || display_alert "${title}" "Failed to enable armbian-ota-firstboot.service" "warn"

    return 0
}

# Build hooks

function pre_update_initramfs__894_install_recovery_ota_hooks() {
    if [[ "${OTA_ENABLE}" != "yes" || "${AB_PART_OTA}" == "yes" ]]; then
        return 0
    fi

    ota_install_recovery_runtime_to_rootfs "${MOUNT}" || return 1
    ota_install_recovery_initramfs "${MOUNT}" || return 1
}

function pre_update_initramfs__895_install_ab_ota_runtime() {
    if [[ "${OTA_ENABLE}" != "yes" || "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    ota_install_ab_runtime_to_rootfs "${MOUNT}" || return 1
    ota_install_ab_tools_to_rootfs "${MOUNT}" || return 1
}

function pre_umount_final_image__896_install_resize_userdata_service() {
    if [[ "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    local title="A/B partition OTA"
    display_alert "${title}" "Installing armbian-resize-userdata service" "info"
    local root_dir="${MOUNT}"
    local -a resize_userdata_file_list=(
        "${OTA_AB_SRC}/systemd/armbian-resize-userdata.service|${OTA_ROOTFS_SYSTEMD_DIR}/armbian-resize-userdata.service|err|0644"
        "${OTA_AB_SRC}/lib/armbian-resize-userdata|${OTA_ROOTFS_LIB_DIR}/armbian-resize-userdata|err|0755"
    )
    ota_install_file_list "${title}" "${root_dir}" "${resize_userdata_file_list[@]}" || return 1

    chroot "${root_dir}" systemctl enable armbian-resize-userdata.service || {
        display_alert "${title}" "Failed to enable armbian-resize-userdata.service" "warn"
    }

    return 0
}
