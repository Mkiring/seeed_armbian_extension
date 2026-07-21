# A/B overlayroot build hook

# Configure overlayroot before Armbian rebuilds the final initramfs.
function pre_update_initramfs__893_config_overlayroot() {
    if [[ "${OTA_ENABLE}" != "yes" || "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    ota_configure_overlayroot "${MOUNT}" "A/B partition OTA" "dev=LABEL=armbi_usrdata"
}
