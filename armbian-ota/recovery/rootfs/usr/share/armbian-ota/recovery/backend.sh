#!/bin/bash

RECOVERY_OVERLAY_BACKING_DIR="/media/root-rw"
RECOVERY_TRANSACTION_DIR="${RECOVERY_OVERLAY_BACKING_DIR}/ota-recovery"
OTA_WORK_DIR="${RECOVERY_TRANSACTION_DIR}/ota_work"
OTA_STATE_DIR="${RECOVERY_TRANSACTION_DIR}/state"
OTA_STATE_FILE="${OTA_STATE_DIR}/ota-state.env"

recovery_require_tools() {
    ota_require_runtime tar sha256sum mount umount mountpoint sed grep awk dd od tr
}

recovery_require_transaction_store() {
    mountpoint -q "${RECOVERY_OVERLAY_BACKING_DIR}" ||
        error_exit "Recovery overlayroot backing store is unavailable: ${RECOVERY_OVERLAY_BACKING_DIR}"
}

recovery_start_ota() {
    local package_path="$1"

    [ -n "${package_path}" ] || error_exit "Usage: armbian-ota start <ota-package.tar.gz>"
    [ -f "${package_path}" ] || error_exit "OTA package not found: ${package_path}"
    recovery_require_tools
    recovery_require_transaction_store
    assert_package_mode_matches "${package_path}" "recovery"

    extract_ota_package "${package_path}" "${OTA_WORK_DIR}"
    ota_verify_payload "${OTA_WORK_DIR}" \
        "${OTA_PAYLOAD_ROOTFS_TAR}" "${OTA_PAYLOAD_ROOTFS_SHA}" \
        "${OTA_PAYLOAD_BOOT_TAR}" "${OTA_PAYLOAD_BOOT_SHA}" "${OTA_PAYLOAD_BOOT_ITB}"
    state_mark_prepared "recovery" "prepared" "${package_path}"

    log_info "Recovery OTA prepared successfully"
    log_info "Reboot to apply the update in initramfs"
}

recovery_mark_success() {
    init_logging
    acquire_lock || error_exit "Cannot acquire OTA lock"
    state_mark_completed "recovery" "success"
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
}
