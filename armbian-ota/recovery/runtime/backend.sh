#!/bin/bash

RECOVERY_ROOTFS_TAR="${OTA_WORK_DIR}/rootfs.tar.gz"
RECOVERY_ROOTFS_SHA="${OTA_WORK_DIR}/rootfs.sha256"
RECOVERY_BOOT_TAR="${OTA_WORK_DIR}/boot.tar.gz"
RECOVERY_BOOT_SHA="${OTA_WORK_DIR}/boot.sha256"

recovery_require_tools() {
    ensure_root
    init_logging
    ensure_command tar sha256sum update-initramfs mount umount sed grep awk
    acquire_lock || error_exit "Cannot acquire OTA lock"
}

recovery_install_initramfs_hooks() {
    local asset_dir hook_src apply_src kver
    asset_dir="$(installed_recovery_asset_dir)"
    hook_src="${asset_dir}/initramfs_hooks/99-copy-tools"
    apply_src="${asset_dir}/initramfs_hooks/99-ota-apply"

    [ -f "${hook_src}" ] || error_exit "Missing recovery hook template: ${hook_src}"
    [ -f "${apply_src}" ] || error_exit "Missing recovery apply template: ${apply_src}"

    mkdir -p /etc/initramfs-tools/hooks /etc/initramfs-tools/scripts/init-premount
    cp "${hook_src}" /etc/initramfs-tools/hooks/99-copy-tools || error_exit "Failed to install 99-copy-tools"
    cp "${apply_src}" /etc/initramfs-tools/scripts/init-premount/99-ota-apply || error_exit "Failed to install 99-ota-apply"
    chmod 755 /etc/initramfs-tools/hooks/99-copy-tools /etc/initramfs-tools/scripts/init-premount/99-ota-apply

    kver="$(detect_kver)"
    log_info "Rebuilding initramfs for kernel ${kver}"
    update-initramfs -u -k "${kver}" || error_exit "Failed to rebuild initramfs"
}

recovery_start_ota() {
    local package_path="$1"

    [ -n "${package_path}" ] || error_exit "Usage: armbian-ota start --mode=recovery <ota-package.tar.gz>"
    [ -f "${package_path}" ] || error_exit "OTA package not found: ${package_path}"
    recovery_require_tools
    assert_package_mode_matches "${package_path}" "recovery"

    extract_ota_package "${package_path}" "${OTA_WORK_DIR}"
    verify_sha256 "${RECOVERY_ROOTFS_TAR}" "${RECOVERY_ROOTFS_SHA}" "rootfs.tar.gz"
    if [ -f "${RECOVERY_BOOT_TAR}" ] && [ -f "${RECOVERY_BOOT_SHA}" ]; then
        verify_sha256 "${RECOVERY_BOOT_TAR}" "${RECOVERY_BOOT_SHA}" "boot.tar.gz"
    fi

    recovery_install_initramfs_hooks

    state_init
    state_mark_mode "recovery"
    state_mark_status "prepared"
    state_set "PACKAGE_PATH" "$(basename "${package_path}")"
    state_set "CURRENT_SLOT" ""
    state_set "TARGET_SLOT" ""
    state_set "START_TIME" "$(date -Iseconds)"
    state_set "COMPLETE_TIME" ""

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
    local hook_path apply_path
    hook_path="/etc/initramfs-tools/hooks/99-copy-tools"
    apply_path="/etc/initramfs-tools/scripts/init-premount/99-ota-apply"

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
    echo "  99-copy-tools: $([ -f "${hook_path}" ] && echo INSTALLED || echo MISSING)"
    echo "  99-ota-apply: $([ -f "${apply_path}" ] && echo INSTALLED || echo MISSING)"
}
