# Shared userdata resize build hooks

function extension_prepare_config__install_userdata_resize_tools() {
    if [[ "${OTA_ENABLE}" != "yes" ]]; then
        return 0
    fi

    display_alert "OTA userdata" "Installing userdata resize tools" "info"
    add_packages_to_image util-linux parted e2fsprogs
    if ota_encrypted_rootfs_enabled; then
        add_packages_to_image cryptsetup
    fi
}

function pre_umount_final_image__896_install_resize_userdata_service() {
    if [[ "${OTA_ENABLE}" != "yes" ]]; then
        return 0
    fi

    local title="OTA userdata"

    display_alert "${title}" "Enabling armbian-resize-userdata service" "info"
    chroot "${MOUNT}" systemctl enable armbian-resize-userdata.service || {
        display_alert "${title}" "Failed to enable armbian-resize-userdata.service" "warn"
    }
}
