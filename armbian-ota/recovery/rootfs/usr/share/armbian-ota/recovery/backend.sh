#!/bin/bash

RECOVERY_OVERLAY_BACKING_DIR="/media/root-rw"
RECOVERY_TRANSACTION_DIR="${RECOVERY_OVERLAY_BACKING_DIR}/ota-recovery"
OTA_WORK_DIR="${RECOVERY_TRANSACTION_DIR}/ota_work"
OTA_BACKUP_DIR="${RECOVERY_TRANSACTION_DIR}/backup"
OTA_STATE_DIR="${RECOVERY_TRANSACTION_DIR}/state"
OTA_STATE_FILE="${OTA_STATE_DIR}/ota-state.env"
# Rootfs-side mirror seeded by the initramfs at STATUS=applied; kept in
# sync here so the systemd conditions and `armbian-ota status` agree.
OTA_ROOTFS_STATE_FILE="/var/lib/armbian-ota/ota-state.env"

# Image-build knob (design section 7): OTA_KEEP_BACKUP=no degrades to
# no-rollback (apply success deletes ota_work directly).
OTA_KEEP_BACKUP="yes"
[ -f /etc/default/armbian-ota ] && . /etc/default/armbian-ota

recovery_require_tools() {
    ota_require_runtime tar sha256sum mount umount mountpoint sed grep awk dd od tr
}

recovery_require_transaction_store() {
    mountpoint -q "${RECOVERY_OVERLAY_BACKING_DIR}" ||
        error_exit "Recovery overlayroot backing store is unavailable: ${RECOVERY_OVERLAY_BACKING_DIR}"
}

# Design section 8: staging a new package while the previous backup still
# exists is the two-payload peak. When userdata cannot hold both, drop the
# old backup first (the rollback net restarts with the incoming OTA).
recovery_ensure_stage_space() {
    local package_path="$1" avail_kb need_kb

    need_kb=$(( $(stat -c%s "${package_path}") / 1024 + 65536 )) # pkg + 64MiB headroom
    avail_kb="$(df -Pk "${RECOVERY_OVERLAY_BACKING_DIR}" | awk 'NR==2 {print $4}')"

    if [ "${avail_kb}" -ge "${need_kb}" ]; then
        return 0
    fi

    if [ -d "${OTA_BACKUP_DIR}" ]; then
        # Renaming would not free any space: the drop is a real rm. Verify
        # the incoming package is at least readable first, so a corrupt or
        # truncated package cannot cost the board its only rollback net.
        if ! tar -tf "${package_path}" >/dev/null 2>&1; then
            error_exit "OTA package is not readable; keeping previous backup"
        fi
        log_info "userdata short on space (${avail_kb}KiB < ${need_kb}KiB), dropping previous backup to make room"
        rm -rf "${OTA_BACKUP_DIR}"
        avail_kb="$(df -Pk "${RECOVERY_OVERLAY_BACKING_DIR}" | awk 'NR==2 {print $4}')"
    fi

    [ "${avail_kb}" -ge "${need_kb}" ] ||
        error_exit "Not enough space on userdata for the OTA package (${avail_kb}KiB available, ${need_kb}KiB needed)"
}

recovery_start_ota() {
    local package_path="$1"

    [ -n "${package_path}" ] || error_exit "Usage: armbian-ota start <ota-package.tar.gz>"
    [ -f "${package_path}" ] || error_exit "OTA package not found: ${package_path}"
    recovery_require_tools
    recovery_require_transaction_store
    assert_package_mode_matches "${package_path}" "recovery"
    recovery_ensure_stage_space "${package_path}"

    extract_ota_package "${package_path}" "${OTA_WORK_DIR}"
    ota_assert_payload_matches_system "${OTA_WORK_DIR}"
    ota_verify_payload "${OTA_WORK_DIR}" \
        "${OTA_PAYLOAD_ROOTFS_TAR}" "${OTA_PAYLOAD_ROOTFS_SHA}" \
        "${OTA_PAYLOAD_BOOT_TAR}" "${OTA_PAYLOAD_BOOT_SHA}" "${OTA_PAYLOAD_BOOT_ITB}"
    ota_check_package_requirements "${OTA_WORK_DIR}"
    ota_run_phase1_hooks "${OTA_WORK_DIR}"

    # prepared resets the retry budget for the incoming transaction.
    # BACKUP_PARTIAL is deliberately NOT touched: while the firstboot
    # boot-only backup exists the flag must stay 1 (design 3.4); only
    # mark-success clears it after a full payload has been promoted.
    state_mark_prepared "recovery" "prepared" "${package_path}"
    state_set "RETRY_COUNT" "0"

    log_info "Recovery OTA prepared successfully"
    log_info "Reboot to apply the update in initramfs"
}

# Design section 6.5: called by the health-check service only after the
# boot was confirmed healthy. Promotes ota_work/ to backup/ (or deletes it
# when OTA_KEEP_BACKUP=no), syncs the rootfs-side mirror to success. The
# partial flag only clears when the surviving backup carries a rootfs payload.
recovery_mark_success() {
    local status partial_next=0

    init_logging
    acquire_lock || error_exit "Cannot acquire OTA lock"
    recovery_require_transaction_store

    status="$(state_get STATUS)"
    [ "${status}" = "applied" ] ||
        error_exit "recovery mark-success expects STATUS=applied, found '${status}'"

    if [ "${OTA_KEEP_BACKUP}" = "yes" ]; then
        if [ -d "${OTA_WORK_DIR}" ]; then
            # Two-step promote: set the old net aside, land the new one,
            # only then drop the old. A failed promotion restores the old
            # net instead of leaving the board with neither.
            retired="${OTA_BACKUP_DIR}.retired"
            rm -rf "${retired}"
            if [ -d "${OTA_BACKUP_DIR}" ]; then
                mv "${OTA_BACKUP_DIR}" "${retired}" ||
                    error_exit "failed to set aside previous backup/"
            fi
            if mv "${OTA_WORK_DIR}" "${OTA_BACKUP_DIR}"; then
                rm -rf "${retired}"
                log_info "payload promoted: ota_work/ -> backup/"
            else
                [ -d "${retired}" ] && mv "${retired}" "${OTA_BACKUP_DIR}" 2>/dev/null
                error_exit "failed to promote ota_work/ to backup/ (previous backup restored)"
            fi
        elif [ -d "${OTA_BACKUP_DIR}" ]; then
            # ota_work vanished under us (observed 2026-10-28: a stale
            # initramfs convicted the transaction and deleted it). Only
            # clear PARTIAL when the surviving backup still carries a full
            # rootfs payload; a boot-only leftover must keep PARTIAL=1 or
            # the next rollback walks the full-verify path, fails, and
            # clears the net as "corrupt".
            if ls "${OTA_BACKUP_DIR}"/rootfs.tar.* >/dev/null 2>&1; then
                log_info "WARN: ota_work/ gone; backup/ still carries the full payload"
            else
                partial_next=1
                log_info "WARN: ota_work/ gone and backup/ lacks rootfs payload; keeping BACKUP_PARTIAL=1"
            fi
        else
            log_info "WARN: neither ota_work/ nor backup/ present; keeping state only"
        fi
    else
        rm -rf "${OTA_WORK_DIR}"
        log_info "OTA_KEEP_BACKUP=no: ota_work/ deleted (no rollback net)"
    fi

    state_mark_completed "recovery" "success"
    state_set "RETRY_COUNT" "0"
    state_set "BACKUP_PARTIAL" "${partial_next}"

    # keep the rootfs mirror in agreement with the transaction state
    if [ -f "${OTA_ROOTFS_STATE_FILE}" ]; then
        sed -i \
            -e 's/^STATUS=.*/STATUS=success/' \
            -e 's/^RETRY_COUNT=.*/RETRY_COUNT=0/' \
            -e "s/^BACKUP_PARTIAL=.*/BACKUP_PARTIAL=${partial_next}/" \
            "${OTA_ROOTFS_STATE_FILE}" 2>/dev/null || true
    fi

    log_info "Recovery OTA marked successful"
}

recovery_rollback() {
    init_logging
    error_exit "Manual rollback is automatic in recovery mode: a boot that never reaches health confirmation leaves STATUS=applied and the next initramfs boot rolls back onto backup/"
}

recovery_status() {
    echo "=== Armbian OTA Status (Recovery) ==="
    echo "Mode: recovery"
    echo "Status: $(state_get STATUS)"
    echo "Package: $(state_get PACKAGE_PATH)"
    echo "Prepared at: $(state_get START_TIME)"
    echo "Retry: $(state_get RETRY_COUNT)/${OTA_MAX_RETRY:-3}"
    [ -n "$(state_get ERROR_MSG)" ] && echo "Error: $(state_get ERROR_MSG)"
    echo ""
    echo "Work directory:"
    if [ -d "${OTA_WORK_DIR}" ]; then
        echo "  ${OTA_WORK_DIR}"
        ls -la "${OTA_WORK_DIR}" 2>/dev/null | sed 's/^/    /'
    else
        echo "  not present"
    fi
    echo "Backup (rollback net):"
    if [ -d "${OTA_BACKUP_DIR}" ]; then
        echo "  ${OTA_BACKUP_DIR} (partial=$(state_get BACKUP_PARTIAL))"
        ls -la "${OTA_BACKUP_DIR}" 2>/dev/null | sed 's/^/    /'
    else
        echo "  not present"
    fi
}
