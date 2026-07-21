# Recovery overlayroot build hook

function ota_recovery_overlayroot_device_options() {
    if ota_recovery_encrypted_rootfs_enabled; then
        printf '%s\n' 'dev=/dev/mapper/armbian-userdata,timeout=30'
    else
        printf '%s\n' 'dev=LABEL=armbi_usrdata'
    fi
}

function pre_update_initramfs__892_config_recovery_overlayroot() {
    if ! ota_recovery_enabled; then
        return 0
    fi

    ota_configure_overlayroot "${MOUNT}" "Recovery OTA" \
        "$(ota_recovery_overlayroot_device_options)"
}
