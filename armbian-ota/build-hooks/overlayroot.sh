# A/B overlayroot build hooks

function ota_set_config_option() {
    local config_file="$1"
    local key="$2"
    local assignment="$3"

    if grep -q "^${key}=" "${config_file}"; then
        sed -i "s|^${key}=.*|${assignment}|" "${config_file}"
    else
        printf '%s\n' "${assignment}" >> "${config_file}"
    fi
}

# Configure overlayroot before Armbian rebuilds the final initramfs.
function pre_update_initramfs__893_config_overlayroot() {
    if [[ "${OTA_ENABLE}" != "yes" || "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    display_alert "overlayroot" "Configuring overlayroot for A/B partition OTA" "info"
    local root_dir="${MOUNT}"

    if [[ -f "${root_dir}/etc/initramfs-tools/initramfs.conf" ]]; then
        if ota_set_config_option "${root_dir}/etc/initramfs-tools/initramfs.conf" "BUSYBOX" "BUSYBOX=y"; then
            display_alert "overlayroot" "Set BUSYBOX=y in initramfs.conf" "info"
        else
            display_alert "overlayroot" "Failed to set BUSYBOX=y in initramfs.conf" "warn"
        fi
    else
        display_alert "overlayroot" "initramfs.conf not found" "warn"
    fi

    if [[ -f "${root_dir}/etc/overlayroot.conf" ]]; then
        if ota_set_config_option "${root_dir}/etc/overlayroot.conf" "overlayroot" \
            'overlayroot="device:dev=LABEL=armbi_usrdata"'; then
            display_alert "overlayroot" "Set overlayroot in /etc/overlayroot.conf" "info"
        else
            display_alert "overlayroot" "Failed to set overlayroot in /etc/overlayroot.conf" "warn"
        fi
    else
        display_alert "overlayroot" "/etc/overlayroot.conf not found" "warn"
    fi

    # The Debian overlayroot package installs a MOTD script that dumps
    # overlay mount entries on every login. It is noisy for production images.
    if [[ -e "${root_dir}/etc/update-motd.d/97-overlayroot" ]]; then
        rm -f "${root_dir}/etc/update-motd.d/97-overlayroot"
        display_alert "overlayroot" "Removed overlayroot MOTD mount dump" "info"
    fi
}
