#
# Rootfs Runtime Install Hooks
#

function ota_install_runtime_to_rootfs() {
    local root_dir="$1"
    local ota_ext_dir
    ota_ext_dir="${OTA_SUPPORT_DIR}"
    local runtime_src="${ota_ext_dir}/runtime"
    local ab_src="${ota_ext_dir}/ab"
    local recovery_src="${ota_ext_dir}/recovery"
    local default_preserve_list="${runtime_src}/policy/preserve-list.txt"
    local default_persist_map="${runtime_src}/policy/persist-map.txt"

    if [[ ! -d "${runtime_src}" ]]; then
        display_alert "OTA runtime" "runtime source dir missing: ${runtime_src}" "warn"
        return 0
    fi

    display_alert "OTA runtime" "Installing OTA runtime into rootfs" "info"
    mkdir -p "${root_dir}/usr/sbin" "${root_dir}/usr/share/armbian-ota"

    cp "${runtime_src}/bin/armbian-ota" "${root_dir}/usr/sbin/armbian-ota" || {
        display_alert "OTA runtime" "Failed to install armbian-ota CLI" "err"
        return 1
    }
    cp "${runtime_src}/bin/armbian-abctl" "${root_dir}/usr/sbin/armbian-abctl" || {
        display_alert "OTA runtime" "Failed to install armbian-abctl" "err"
        return 1
    }
    cp "${runtime_src}/lib/common.sh" "${root_dir}/usr/share/armbian-ota/common.sh" || {
        display_alert "OTA runtime" "Failed to install common.sh" "err"
        return 1
    }
    cp "${runtime_src}/lib/state.sh" "${root_dir}/usr/share/armbian-ota/state.sh" || {
        display_alert "OTA runtime" "Failed to install state.sh" "err"
        return 1
    }
    cp "${runtime_src}/lib/persist.sh" "${root_dir}/usr/share/armbian-ota/persist.sh" || {
        display_alert "OTA runtime" "Failed to install persist.sh" "err"
        return 1
    }
    cp "${runtime_src}/lib/preserve.sh" "${root_dir}/usr/share/armbian-ota/preserve.sh" || {
        display_alert "OTA runtime" "Failed to install preserve.sh" "err"
        return 1
    }

    if [[ -f "${default_preserve_list}" ]]; then
        mkdir -p "${root_dir}/etc/armbian-ota"
        if [[ -f "${root_dir}/etc/armbian-ota/preserve-list.txt" ]]; then
            cp "${default_preserve_list}" "${root_dir}/etc/armbian-ota/preserve-list.txt.default" || {
                display_alert "OTA runtime" "Failed to install default preserve-list.txt.default" "warn"
            }
        else
            cp "${default_preserve_list}" "${root_dir}/etc/armbian-ota/preserve-list.txt" || {
                display_alert "OTA runtime" "Failed to install default preserve-list.txt" "warn"
            }
        fi
    fi

    if [[ -f "${default_persist_map}" ]]; then
        mkdir -p "${root_dir}/etc/armbian-ota"
        if [[ -f "${root_dir}/etc/armbian-ota/persist-map.txt" ]]; then
            cp "${default_persist_map}" "${root_dir}/etc/armbian-ota/persist-map.txt.default" || {
                display_alert "OTA runtime" "Failed to install default persist-map.txt.default" "warn"
            }
        else
            cp "${default_persist_map}" "${root_dir}/etc/armbian-ota/persist-map.txt" || {
                display_alert "OTA runtime" "Failed to install default persist-map.txt" "warn"
            }
        fi
    fi

    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        cp "${ab_src}/backend.sh" "${root_dir}/usr/share/armbian-ota/backend-ab.sh" || {
            display_alert "OTA runtime" "Failed to install backend-ab.sh" "err"
            return 1
        }
    else
        cp "${recovery_src}/backend.sh" "${root_dir}/usr/share/armbian-ota/backend-recovery.sh" || {
            display_alert "OTA runtime" "Failed to install backend-recovery.sh" "err"
            return 1
        }
        if [[ -d "${recovery_src}" ]]; then
            mkdir -p "${root_dir}/usr/share/armbian-ota/recovery"
            cp -a "${recovery_src}/." "${root_dir}/usr/share/armbian-ota/recovery/" || {
                display_alert "OTA runtime" "Failed to install recovery runtime assets" "err"
                return 1
            }
        fi
    fi

    chmod +x "${root_dir}/usr/sbin/armbian-ota" "${root_dir}/usr/sbin/armbian-abctl" "${root_dir}/usr/share/armbian-ota/common.sh" "${root_dir}/usr/share/armbian-ota/state.sh" "${root_dir}/usr/share/armbian-ota/persist.sh" "${root_dir}/usr/share/armbian-ota/preserve.sh"
    [[ -f "${root_dir}/usr/share/armbian-ota/backend-ab.sh" ]] && chmod +x "${root_dir}/usr/share/armbian-ota/backend-ab.sh"
    [[ -f "${root_dir}/usr/share/armbian-ota/backend-recovery.sh" ]] && chmod +x "${root_dir}/usr/share/armbian-ota/backend-recovery.sh"

    return 0
}

function ota_install_recovery_initramfs_hooks() {
    local root_dir="$1"
    local ota_ext_dir="${OTA_SUPPORT_DIR}"
    local recovery_src="${ota_ext_dir}/recovery"
    local copy_tools_src="${recovery_src}/initramfs_hooks/99-copy-tools"
    local ota_apply_src="${recovery_src}/initramfs_hooks/99-ota-apply"
    local cache_stamp="${root_dir}/etc/initramfs-tools/conf.d/armbian-ota-runtime.hash"

    [[ -f "${copy_tools_src}" && -f "${ota_apply_src}" ]] || {
        display_alert "Recovery OTA initramfs" "Recovery initramfs hook sources are missing" "err"
        return 1
    }

    display_alert "Recovery OTA initramfs" "Installing recovery OTA hooks into target initramfs" "info"
    mkdir -p \
        "${root_dir}/etc/initramfs-tools/hooks" \
        "${root_dir}/etc/initramfs-tools/scripts/init-premount" \
        "${root_dir}/etc/initramfs-tools/conf.d"

    cp "${copy_tools_src}" "${root_dir}/etc/initramfs-tools/hooks/99-copy-tools" || {
        display_alert "Recovery OTA initramfs" "Failed to install 99-copy-tools" "err"
        return 1
    }
    cp "${ota_apply_src}" "${root_dir}/etc/initramfs-tools/scripts/init-premount/99-ota-apply" || {
        display_alert "Recovery OTA initramfs" "Failed to install 99-ota-apply" "err"
        return 1
    }
    chmod 755 \
        "${root_dir}/etc/initramfs-tools/hooks/99-copy-tools" \
        "${root_dir}/etc/initramfs-tools/scripts/init-premount/99-ota-apply"

    {
        cd "${root_dir}" || exit 1
        for ota_runtime_file in \
            "usr/share/armbian-ota/state.sh" \
            "usr/share/armbian-ota/persist.sh" \
            "usr/share/armbian-ota/preserve.sh" \
            "etc/initramfs-tools/hooks/99-copy-tools" \
            "etc/initramfs-tools/scripts/init-premount/99-ota-apply"
        do
            [[ -f "${ota_runtime_file}" ]] || continue
            sha256sum "${ota_runtime_file}"
        done
    } > "${cache_stamp}" || {
        display_alert "Recovery OTA initramfs" "Failed to write initramfs cache stamp" "err"
        return 1
    }

    return 0
}

function pre_update_initramfs__894_install_recovery_ota_hooks() {
    if [[ "${OTA_ENABLE}" != "yes" || "${AB_PART_OTA}" == "yes" ]]; then
        return 0
    fi

    ota_install_runtime_to_rootfs "${MOUNT}" || return 1
    ota_install_recovery_initramfs_hooks "${MOUNT}" || return 1
}

function pre_umount_final_image__894_install_ota_runtime() {
    if [[ "${OTA_ENABLE}" != "yes" ]]; then
        return 0
    fi

    ota_install_runtime_to_rootfs "${MOUNT}"
}

# Function to install AB OTA manager and related tools
function pre_umount_final_image__895_install_ab_tools() {
    if [[ "${OTA_ENABLE}" != "yes" ]]; then
        return 0
    fi

    local root_dir="${MOUNT}"
    local ota_ext_dir
    ota_ext_dir="${OTA_SUPPORT_DIR}"

    mkdir -p "${root_dir}/usr/sbin" "${root_dir}/usr/lib/armbian" "${root_dir}/etc/systemd/system"

    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        display_alert "A/B partition OTA" "Installing AB OTA userspace tools" "info"
        local ab_src="${ota_ext_dir}/ab"

        cp "${ab_src}/lib/armbian-ota-health-check" "${root_dir}/usr/lib/armbian/armbian-ota-health-check" || {
            display_alert "A/B partition OTA" "Failed to install armbian-ota-health-check" "err"
            return 1
        }
        cp "${ab_src}/lib/armbian-ota-init-uboot" "${root_dir}/usr/lib/armbian/armbian-ota-init-uboot" || {
            display_alert "A/B partition OTA" "Failed to install armbian-ota-init-uboot" "err"
            return 1
        }
        chmod +x "${root_dir}/usr/lib/armbian/armbian-ota-health-check" "${root_dir}/usr/lib/armbian/armbian-ota-init-uboot"

        local services=(
            "armbian-ota-init-uboot.service"
            "armbian-ota-firstboot.service"
            "armbian-ota-mark-success.service"
            "armbian-ota-rollback.service"
        )
        local svc
        for svc in "${services[@]}"; do
            cp "${ab_src}/systemd/${svc}" "${root_dir}/etc/systemd/system/${svc}" || {
                display_alert "A/B partition OTA" "Failed to install ${svc}" "warn"
            }
        done

        chroot "${root_dir}" systemctl enable armbian-ota-init-uboot.service || display_alert "A/B partition OTA" "Failed to enable armbian-ota-init-uboot.service" "warn"
        chroot "${root_dir}" systemctl enable armbian-ota-firstboot.service || display_alert "A/B partition OTA" "Failed to enable armbian-ota-firstboot.service" "warn"
    fi

    return 0
}

function pre_umount_final_image__896_install_resize_userdata_service() {
    if [[ "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    display_alert "A/B partition OTA" "Installing armbian-resize-userdata service" "info"
    local root_dir="${MOUNT}"
    local ota_ext_dir
    ota_ext_dir="${OTA_SUPPORT_DIR}"

    mkdir -p "${root_dir}/etc/systemd/system" "${root_dir}/usr/lib/armbian"

    cp "${ota_ext_dir}/ab/systemd/armbian-resize-userdata.service" "${root_dir}/etc/systemd/system/" || {
        display_alert "A/B partition OTA" "Failed to copy armbian-resize-userdata.service" "err"
        return 1
    }
    cp "${ota_ext_dir}/ab/lib/armbian-resize-userdata" "${root_dir}/usr/lib/armbian/" || {
        display_alert "A/B partition OTA" "Failed to copy armbian-resize-userdata script" "err"
        return 1
    }
    chmod +x "${root_dir}/usr/lib/armbian/armbian-resize-userdata"

    chroot "${root_dir}" systemctl enable armbian-resize-userdata.service || {
        display_alert "A/B partition OTA" "Failed to enable armbian-resize-userdata.service" "warn"
    }

    return 0
}
