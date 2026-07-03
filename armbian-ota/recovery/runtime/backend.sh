#!/bin/bash

RECOVERY_ROOTFS_TAR="${OTA_WORK_DIR}/rootfs.tar.gz"
RECOVERY_ROOTFS_SHA="${OTA_WORK_DIR}/rootfs.sha256"
RECOVERY_BOOT_TAR="${OTA_WORK_DIR}/boot.tar.gz"
RECOVERY_BOOT_SHA="${OTA_WORK_DIR}/boot.sha256"
RECOVERY_COPY_TOOLS_HOOK="/etc/initramfs-tools/hooks/99-copy-tools"
RECOVERY_OTA_APPLY_HOOK="/etc/initramfs-tools/scripts/init-premount/99-ota-apply"

recovery_hook_status() {
    [ -f "$1" ] && echo "INSTALLED" || echo "MISSING"
}

recovery_require_tools() {
    ensure_root
    init_logging
    ensure_command tar sha256sum update-initramfs mount umount sed grep awk
    acquire_lock || error_exit "Cannot acquire OTA lock"
}

recovery_install_initramfs_hooks() {
    local asset_dir copy_tools_src ota_apply_src kver

    asset_dir="$(installed_recovery_asset_dir)"
    copy_tools_src="${asset_dir}/initramfs_hooks/99-copy-tools"
    ota_apply_src="${asset_dir}/initramfs_hooks/99-ota-apply"

    [ -f "${copy_tools_src}" ] || error_exit "Missing recovery hook template: ${copy_tools_src}"
    [ -f "${ota_apply_src}" ] || error_exit "Missing recovery apply template: ${ota_apply_src}"

    mkdir -p /etc/initramfs-tools/hooks /etc/initramfs-tools/scripts/init-premount
    cp "${copy_tools_src}" "${RECOVERY_COPY_TOOLS_HOOK}" || error_exit "Failed to install 99-copy-tools"
    cp "${ota_apply_src}" "${RECOVERY_OTA_APPLY_HOOK}" || error_exit "Failed to install 99-ota-apply"
    chmod 755 "${RECOVERY_COPY_TOOLS_HOOK}" "${RECOVERY_OTA_APPLY_HOOK}"

    kver="$(detect_kver)"
    log_info "Rebuilding initramfs for kernel ${kver}"
    update-initramfs -u -k "${kver}" || error_exit "Failed to rebuild initramfs"
}

recovery_verify_payload() {
    verify_sha256 "${RECOVERY_ROOTFS_TAR}" "${RECOVERY_ROOTFS_SHA}" "rootfs.tar.gz"

    if [ -f "${RECOVERY_BOOT_TAR}" ] && [ -f "${RECOVERY_BOOT_SHA}" ]; then
        verify_sha256 "${RECOVERY_BOOT_TAR}" "${RECOVERY_BOOT_SHA}" "boot.tar.gz"
    fi
}

recovery_mark_prepared() {
    local package_path="$1"

    state_init
    state_mark_mode "recovery"
    state_mark_status "prepared"
    state_set "PACKAGE_PATH" "$(basename "${package_path}")"
    state_set "CURRENT_SLOT" ""
    state_set "TARGET_SLOT" ""
    state_set "START_TIME" "$(date -Iseconds)"
    state_set "COMPLETE_TIME" ""
}

recovery_start_ota() {
    local package_path="$1"

    [ -n "${package_path}" ] || error_exit "Usage: armbian-ota start <ota-package.tar.gz>"
    [ -f "${package_path}" ] || error_exit "OTA package not found: ${package_path}"
    recovery_require_tools
    assert_package_mode_matches "${package_path}" "recovery"

    extract_ota_package "${package_path}" "${OTA_WORK_DIR}"
    recovery_verify_payload
    recovery_install_initramfs_hooks
    recovery_mark_prepared "${package_path}"

    log_info "Recovery OTA prepared successfully"
    log_info "Reboot to apply the update in initramfs"
}

recovery_mark_success() {
    init_logging
    acquire_lock || error_exit "Cannot acquire OTA lock"
    state_init
    state_mark_mode "recovery"
    state_mark_status "success"
    state_set "COMPLETE_TIME" "$(date -Iseconds)"
    log_info "Recovery OTA marked successful"
}

recovery_rollback() {
    init_logging
    error_exit "Rollback is not supported in recovery mode"
}

recovery_status() {
    echo "=== Armbian OTA Status (Recovery) ==="
    echo "Mode: recovery"
    echo "Status: $(state_get STATUS)"
    echo "Package: $(state_get PACKAGE_PATH)"
    echo "Prepared at: $(state_get START_TIME)"
    echo ""
    echo "Work directory:"
    if [ -d "${OTA_WORK_DIR}" ]; then
        echo "  ${OTA_WORK_DIR}"
        ls -la "${OTA_WORK_DIR}" 2>/dev/null | sed 's/^/    /'
    else
        echo "  not present"
    fi
    echo ""
    echo "Initramfs hooks:"
    echo "  99-copy-tools: $(recovery_hook_status "${RECOVERY_COPY_TOOLS_HOOK}")"
    echo "  99-ota-apply: $(recovery_hook_status "${RECOVERY_OTA_APPLY_HOOK}")"
}
