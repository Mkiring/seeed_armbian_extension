#!/bin/sh
#
# initramfs OTA library: payload apply, FIT write, config patch, state commit.
#
# Sourced by 99-ota-apply AFTER ota-log.sh and ota-device.sh (uses log/heartbeat
# and device primitives) and state.sh (uses ota_state_write_file).
# /bin/sh + busybox userland.
#
# Expects globals from the orchestrator: ROOT_MNT, BOOT_MNT, STATE_DIR,
# STATE_FILE, OTA_DIR, ROOTFS_TAR, BOOT_TAR, BOOT_ITB.
# Reads globals from ota_detect_devices: ROOT_UUID, BOOT_DEV, BOOT_UUID,
# HAS_BOOT_PART, AUTO_DECRYPT_MODE.
# Sets globals: HAS_BOOT_TAR, HAS_BOOT_ITB, DO_BOOT_OTA, BOOT_MNT (reassigned).

# ===== tar extract helper with fallback and stderr logging =====
extract_tar_with_fallback() {
    archive="$1"
    target="$2"
    label="$3"
    err_file="${LOGDIR}/${label}.tar.stderr.log"
    rc=0

    rm -f "${err_file}" 2>/dev/null || true

    # Preferred mode: preserve metadata when supported.
    log "${label}: run tar --xattrs --acls --numeric-owner -xpf ${archive} -C ${target}"
    if tar --xattrs --acls --numeric-owner -xpf "${archive}" -C "${target}" 2>"${err_file}"; then
        log "${label}: metadata extract succeeded"
        log_tail "${label}" "${err_file}" 20
        rm -f "${err_file}" 2>/dev/null || true
        return 0
    fi
    rc=$?

    log "WARN: ${label} metadata extract failed (rc=${rc}), retrying with plain tar -xzf"
    log_tail "${label} metadata stderr" "${err_file}" 40

    rm -f "${err_file}" 2>/dev/null || true
    log "${label}: run tar -xzf ${archive} -C ${target}"
    if tar -xzf "${archive}" -C "${target}" 2>"${err_file}"; then
        log "${label}: plain extract succeeded"
        log_tail "${label}" "${err_file}" 20
        rm -f "${err_file}" 2>/dev/null || true
        return 0
    fi
    rc=$?

    log "ERROR: ${label} extract failed in both metadata and plain modes (plain rc=${rc})"
    log_tail "${label} stderr" "${err_file}" 80
    rm -f "${err_file}" 2>/dev/null || true
    return 1
}

set_env_key() {
    file="$1"
    key="$2"
    value="$3"

    if grep -q "^${key}=" "${file}"; then
        sed -i "s|^${key}=.*$|${key}=${value}|" "${file}"
    else
        printf '\n%s=%s\n' "${key}" "${value}" >> "${file}"
    fi
}

write_raw_boot_itb() {
    image="$1"
    target="$2"

    [ -f "${image}" ] || return 0
    [ -b "${target}" ] || {
        log "ERROR: boot.itb target is not a block device: ${target}"
        return 1
    }

    partname="$(get_partname_for_dev "${target}" || true)"
    [ "${partname}" = "boot" ] || {
        log "ERROR: refusing to write boot.itb to ${target}: PARTNAME=${partname:-<empty>}"
        return 1
    }

    if ! is_fit_image "${image}"; then
        log "ERROR: refusing to write invalid FIT image: ${image}"
        return 1
    fi

    image_size="$(file_size_bytes "${image}")"
    target_size="$(blockdev_size_bytes "${target}")"
    if [ -z "${image_size}" ] || [ -z "${target_size}" ] || [ "${image_size}" -gt "${target_size}" ]; then
        log "ERROR: boot.itb size check failed: image=${image_size:-unknown}, target=${target_size:-unknown}"
        return 1
    fi

    log "writing raw FIT boot image ${image} (${image_size} bytes) -> ${target} (${target_size} bytes)"
    start_heartbeat "writing boot.itb to ${target}"
    if ! dd if="${image}" of="${target}" bs=4M conv=fsync 2>>"${LOGFILE}"; then
        stop_heartbeat
        log "ERROR: failed to write boot.itb to ${target}"
        return 1
    fi
    stop_heartbeat
    sync
}

# ===== validate recovery state on mounted rootfs =====
# Returns 1 (caller unmounts+skips) when state/payload is not applicable.
ota_validate_recovery_state() {
    if [ ! -f "${STATE_FILE}" ]; then
        log "no OTA state file at ${STATE_FILE}, unmount and skip"
        return 1
    fi

    if ! grep -q '^OTA_MODE=recovery$' "${STATE_FILE}" 2>/dev/null ||
       ! grep -q '^STATUS=prepared$' "${STATE_FILE}" 2>/dev/null; then
        log "OTA state is not recovery/prepared, unmount and skip"
        return 1
    fi

    # check OTA payload: rootfs.tar.gz is required, boot.tar.gz is optional
    if [ ! -d "${OTA_DIR}" ] || [ ! -f "${ROOTFS_TAR}" ]; then
        log "no rootfs OTA payload at ${OTA_DIR}, unmount and skip"
        return 1
    fi

    HAS_BOOT_TAR=0
    [ -f "${BOOT_TAR}" ] && HAS_BOOT_TAR=1
    HAS_BOOT_ITB=0
    [ -f "${BOOT_ITB}" ] && HAS_BOOT_ITB=1

    log "found rootfs OTA payload, HAS_BOOT_PART=${HAS_BOOT_PART}, HAS_BOOT_TAR=${HAS_BOOT_TAR}, HAS_BOOT_ITB=${HAS_BOOT_ITB}"
    return 0
}

# ===== clean rootfs (except boot) + extract rootfs.tar.gz =====
# Returns 1 (caller unmounts+aborts) on clean/extract failure.
ota_apply_rootfs() {
    log "cleaning ${ROOT_MNT} (except boot)..."
    start_heartbeat "cleaning rootfs at ${ROOT_MNT}"
    (
        cd "${ROOT_MNT}" || exit 1
        for f in * .[!.]* ..?*; do
            case "$f" in
                "."|".."|"boot")
                    continue
                    ;;
            esac
            rm -rf "$f"
        done
    ) || {
        stop_heartbeat
        log "ERROR: failed to clean ${ROOT_MNT}, abort OTA"
        return 1
    }
    stop_heartbeat

    log "extracting ${ROOTFS_TAR} -> ${ROOT_MNT} ..."
    start_heartbeat "extracting rootfs.tar.gz to ${ROOT_MNT}"
    if ! extract_tar_with_fallback "${ROOTFS_TAR}" "${ROOT_MNT}" "rootfs"; then
        stop_heartbeat
        log "ERROR: extract rootfs.tar.gz failed, abort OTA"
        return 1
    fi
    stop_heartbeat

    sync

    # Force-disable Armbian first-login marker after OTA. If new rootfs ships this
    # file, root login would trigger first-login flow unexpectedly.
    if rm -f "${ROOT_MNT}/root/.not_logged_in_yet" 2>/dev/null; then
        log "removed ${ROOT_MNT}/root/.not_logged_in_yet to avoid first-login re-trigger"
    fi

    # Clean stale getty autologin overrides. These are normally removed by
    # armbian-firstlogin; when firstlogin is skipped they may persist.
    for ov in \
        "${ROOT_MNT}/etc/systemd/system/getty@.service.d/override.conf" \
        "${ROOT_MNT}/etc/systemd/system/serial-getty@.service.d/override.conf"
    do
        if [ -f "${ov}" ]; then
            if grep -Eq -- 'autologin|--autologin' "${ov}" 2>/dev/null; then
                if rm -f "${ov}" 2>/dev/null; then
                    log "removed stale autologin override: ${ov}"
                else
                    log "WARN: failed to remove stale autologin override: ${ov}"
                fi
            else
                log "keep non-autologin override: ${ov}"
            fi
        fi
    done

    return 0
}

# ===== boot OTA: mount boot partition, extract boot.tar.gz, write boot.itb =====
# Returns 1 on boot.itb failure (caller unmounts+aborts). boot.tar.gz extract
# failure is logged but does not abort (matches legacy behavior).
ota_apply_boot() {
    DO_BOOT_OTA=0
    [ "$HAS_BOOT_PART" -eq 1 ] && [ "$HAS_BOOT_TAR" -eq 1 ] && DO_BOOT_OTA=1

    if [ "$DO_BOOT_OTA" -eq 1 ]; then
        log "boot OTA enabled (separate boot partition + boot.tar.gz present)"

        mkdir -p "${BOOT_MNT}"
        log "mounting ${BOOT_DEV} -> ${BOOT_MNT} ..."
        if ! mount -t ext4 -o rw "${BOOT_DEV}" "${BOOT_MNT}"; then
            log "ERROR: mount ${BOOT_DEV} failed, skip boot OTA"
            BOOT_MNT=""
            DO_BOOT_OTA=0
        fi
    else
        log "boot OTA disabled (no separate boot partition or no boot.tar.gz)"
    fi

    if [ "$DO_BOOT_OTA" -eq 1 ]; then
        log "extracting ${BOOT_TAR} -> ${BOOT_MNT} ..."
        start_heartbeat "extracting boot.tar.gz to ${BOOT_MNT}"
        if ! extract_tar_with_fallback "${BOOT_TAR}" "${BOOT_MNT}" "boot"; then
            stop_heartbeat
            log "ERROR: extract boot.tar.gz failed, system may be broken"
        fi
        stop_heartbeat

        sync
    fi

    if [ "${HAS_BOOT_ITB}" -eq 1 ]; then
        RAW_BOOT_DEV="$(find_raw_boot_dev || true)"
        if [ -z "${RAW_BOOT_DEV}" ]; then
            log "ERROR: boot.itb present but no PARTNAME=boot raw boot partition found"
            return 1
        fi
        if ! write_raw_boot_itb "${BOOT_ITB}" "${RAW_BOOT_DEV}"; then
            log "ERROR: raw boot.itb update failed, abort OTA"
            return 1
        fi
    fi

    return 0
}

# ===== fix UUIDs in armbianEnv.txt and new rootfs /etc/fstab (+ crypttab) =====
ota_patch_config() {
    if [ "$DO_BOOT_OTA" -eq 1 ] && [ -n "${BOOT_MNT}" ]; then
        ARM_ENV="${BOOT_MNT}/armbianEnv.txt"
    else
        ARM_ENV="${ROOT_MNT}/boot/armbianEnv.txt"
    fi

    FSTAB="${ROOT_MNT}/etc/fstab"
    CRYPTTAB="${ROOT_MNT}/etc/crypttab"

    # fallback UUID detection (just in case)
    if [ "${AUTO_DECRYPT_MODE}" -eq 1 ]; then
        [ -z "$ROOT_UUID" ] && ROOT_UUID="$(get_luks_uuid_for_root)"
    else
        [ -z "$ROOT_UUID" ] && ROOT_UUID="$(get_uuid_by_label "armbi_root")"
    fi
    [ -z "$BOOT_UUID" ] && BOOT_UUID="$(get_uuid_by_label "armbi_boot")"

    log "final ROOT_UUID=${ROOT_UUID}, BOOT_UUID=${BOOT_UUID}"

    # patch armbianEnv.txt if present
    if [ -f "${ARM_ENV}" ]; then
        log "patching ${ARM_ENV} ..."

        if [ "${AUTO_DECRYPT_MODE}" -eq 1 ]; then
            log "  - set rootdev=/dev/mapper/armbian-root"
            set_env_key "${ARM_ENV}" rootdev /dev/mapper/armbian-root
        else
            if [ -n "${ROOT_UUID}" ]; then
                log "  - set rootdev=UUID=${ROOT_UUID}"
                set_env_key "${ARM_ENV}" rootdev "UUID=${ROOT_UUID}"
            else
                log "  - WARN: ROOT_UUID empty, skip rootdev change"
            fi
        fi

        # Keep existing console settings. Overriding serial console here may break
        # user-observed boot logs/login on boards using different UARTs.
        if grep -q '^console=' "${ARM_ENV}"; then
            log "  - keep existing console setting"
        else
            log "  - no console= in armbianEnv, leave unchanged"
        fi

        log "  - set verbosity=6"
        set_env_key "${ARM_ENV}" verbosity 6
    else
        log "WARN: ${ARM_ENV} not found, cannot patch rootdev/verbosity"
    fi

    # patch new rootfs /etc/fstab
    if [ -f "${FSTAB}" ]; then
        log "patching ${FSTAB} ..."

        if [ "${AUTO_DECRYPT_MODE}" -eq 1 ]; then
            log "  - update / entry to /dev/mapper/armbian-root"
            sed -i -E 's|^UUID=[^[:space:]]+[[:space:]]+/[[:space:]]+|/dev/mapper/armbian-root / |' "${FSTAB}"
            sed -i -E 's|^/dev/[^[:space:]]+[[:space:]]+/[[:space:]]+|/dev/mapper/armbian-root / |' "${FSTAB}"
        else
            if [ -n "${ROOT_UUID}" ]; then
                log "  - update / entry UUID to ${ROOT_UUID}"
                # lines like: UUID=xxxx / ext4 ...
                sed -i -E "s|^UUID=[^[:space:]]+[[:space:]]+/[[:space:]]+|UUID=${ROOT_UUID} / |" "${FSTAB}"
            else
                log "  - WARN: ROOT_UUID empty, skip / fstab entry update"
            fi
        fi

        if [ -n "${BOOT_UUID}" ]; then
            log "  - update /boot entry UUID to ${BOOT_UUID}"
            # lines like: UUID=xxxx /boot ext4 ...
            sed -i -E "s|^UUID=[^[:space:]]+[[:space:]]+/boot[[:space:]]+|UUID=${BOOT_UUID} /boot |" "${FSTAB}"
        else
            log "  - WARN: BOOT_UUID empty, skip /boot fstab entry update"
        fi
    else
        log "WARN: ${FSTAB} not found, skip fstab UUID patch"
    fi

    # patch new rootfs /etc/crypttab for auto-decrypt mode
    if [ "${AUTO_DECRYPT_MODE}" -eq 1 ]; then
        if [ -f "${CRYPTTAB}" ]; then
            if [ -n "${ROOT_UUID}" ]; then
                log "patching ${CRYPTTAB} ..."
                log "  - set armbian-root source UUID=${ROOT_UUID} (crypto_LUKS)"
                sed -i -E "s|^(armbian-root[[:space:]]+)UUID=[0-9a-fA-F-]+|\1UUID=${ROOT_UUID}|" "${CRYPTTAB}"
            else
                log "WARN: LUKS UUID empty, skip crypttab patch"
            fi
        else
            log "WARN: ${CRYPTTAB} not found, skip crypttab UUID patch"
        fi
    fi

    sync
}

# ===== write success state via state.sh helper =====
ota_commit_success_state() {
    mkdir -p "${STATE_DIR}"
    PACKAGE_PATH_VALUE="$(grep -E '^PACKAGE_PATH=' "${STATE_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    START_TIME_VALUE="$(grep -E '^START_TIME=' "${STATE_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    COMPLETE_TIME_VALUE="$(date -Iseconds)"
    if command -v ota_state_write_file >/dev/null 2>&1; then
        (
            OTA_STATE_MODE=recovery
            OTA_STATE_STATUS=success
            OTA_STATE_PACKAGE_PATH="${PACKAGE_PATH_VALUE}"
            OTA_STATE_START_TIME="${START_TIME_VALUE}"
            OTA_STATE_COMPLETE_TIME="${COMPLETE_TIME_VALUE}"
            ota_state_write_file "${STATE_FILE}"
        ) || log "WARN: failed to write ${STATE_FILE}"
    else
        log "WARN: state helper not available, failed to write ${STATE_FILE}"
    fi
}

# ===== unmount partitions (normal path; logs WARN on failure) =====
ota_unmount_all() {
    if [ "$DO_BOOT_OTA" -eq 1 ] && [ -n "${BOOT_MNT}" ]; then
        log "unmounting ${BOOT_MNT} ..."
        umount "${BOOT_MNT}" 2>/dev/null || log "WARN: umount ${BOOT_MNT} failed"
    fi

    log "unmounting ${ROOT_MNT} ..."
    umount "${ROOT_MNT}" 2>/dev/null  || log "WARN: umount ${ROOT_MNT} failed"
}
