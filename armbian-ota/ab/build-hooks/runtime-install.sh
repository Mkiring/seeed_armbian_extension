# A/B OTA rootfs installation hooks

function ota_install_ab_runtime_to_rootfs() {
    local root_dir="$1"

    ota_install_common_runtime_to_rootfs "${root_dir}" || return 1
    ota_sync_rootfs "A/B OTA runtime" "${OTA_AB_ROOTFS}" "${root_dir}"
}

function ota_enable_ab_runtime_services() {
    local root_dir="$1"
    local title="A/B partition OTA"

    display_alert "${title}" "Enabling A/B OTA services" "info"
    chroot "${root_dir}" systemctl enable armbian-ota-init-uboot.service \
        || display_alert "${title}" "Failed to enable armbian-ota-init-uboot.service" "warn"
    chroot "${root_dir}" systemctl enable armbian-ota-firstboot.service \
        || display_alert "${title}" "Failed to enable armbian-ota-firstboot.service" "warn"
}

function pre_update_initramfs__895_install_ab_ota_runtime() {
    if [[ "${OTA_ENABLE}" != "yes" || "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    ota_install_ab_runtime_to_rootfs "${MOUNT}" || return 1
    ota_enable_ab_runtime_services "${MOUNT}"
}
