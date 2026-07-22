# A/B inactive-slot payload update helpers.

ota_source_library "${OTA_RUNTIME_DIR}/ab/security.sh" "A/B security helper" || return 1

ab_log_extract_progress() {
    local label="$1"
    local percent next=10

    while read -r percent; do
        percent="${percent%.*}"
        case "${percent}" in
            ''|*[!0-9]*) continue ;;
        esac

        while [ "${percent}" -ge "${next}" ] && [ "${next}" -le 100 ]; do
            log_info "${label} extract progress: ${next}%"
            next=$((next + 10))
        done
    done
}

ab_extract_tar_gz_payload() {
    local archive="$1"
    local target="$2"
    local label="$3"
    local size

    log_info "Extracting ${label} payload"

    if command -v pv >/dev/null 2>&1; then
        size="$(stat -c '%s' "${archive}" 2>/dev/null || true)"
        if [ -n "${size}" ]; then
            pv -f -n -s "${size}" "${archive}" 2> >(ab_log_extract_progress "${label}" >&2) |
                tar --xattrs --acls --numeric-owner -xzf - -C "${target}"
        else
            pv -f "${archive}" | tar --xattrs --acls --numeric-owner -xzf - -C "${target}"
        fi
        return $?
    fi

    tar --xattrs --acls --numeric-owner -xzf "${archive}" -C "${target}"
}

ab_write_target_state() {
    local root_mnt="$1"
    local package_path="$2"
    local current_slot="$3"
    local target_slot="$4"
    local state_file start_time

    state_file="${root_mnt}/var/lib/armbian-ota/ota-state.env"
    start_time="$(date -Iseconds)"

    (
        OTA_STATE_MODE=ab
        OTA_STATE_STATUS=ready_to_boot
        OTA_STATE_PACKAGE_PATH="$(basename "${package_path}")"
        OTA_STATE_CURRENT_SLOT="${current_slot}"
        OTA_STATE_TARGET_SLOT="${target_slot}"
        OTA_STATE_START_TIME="${start_time}"
        ota_state_write_file "${state_file}"
    ) || error_exit "Failed to write target OTA state"
}

ab_apply_target_rootfs() {
    local temp_work="$1"
    local root_mnt="$2"
    local package_path="$3"
    local current_slot="$4"
    local target_slot="$5"

    empty_mount_dir "${root_mnt}" || return 1
    ab_extract_tar_gz_payload "${temp_work}/${OTA_PAYLOAD_ROOTFS_TAR}" "${root_mnt}" "rootfs" || return 1
    ab_write_target_state "${root_mnt}" "${package_path}" "${current_slot}" "${target_slot}"
}

ab_update_armbian_env() {
    local arm_env="$1"
    local root_type="$2"
    local root_uuid="$3"

    [ -f "${arm_env}" ] || return 0

    if [ "${root_type}" = "crypto_LUKS" ]; then
        if grep -q '^rootdev=' "${arm_env}"; then
            sed -i 's|^rootdev=.*$|rootdev=/dev/mapper/armbian-root|' "${arm_env}" || return 1
        else
            printf '\nrootdev=/dev/mapper/armbian-root\n' >> "${arm_env}" || return 1
        fi

        [ -n "${root_uuid}" ] || return 0
        if grep -q '^cryptdevice=' "${arm_env}"; then
            sed -i "s|^cryptdevice=.*$|cryptdevice=UUID=${root_uuid}:armbian-root|" "${arm_env}" || return 1
        else
            printf 'cryptdevice=UUID=%s:armbian-root\n' "${root_uuid}" >> "${arm_env}" || return 1
        fi
        return 0
    fi

    [ -n "${root_uuid}" ] || return 0
    if grep -q '^rootdev=' "${arm_env}"; then
        sed -i "s|^rootdev=UUID=.*$|rootdev=UUID=${root_uuid}|" "${arm_env}" || return 1
        sed -i "s|^rootdev=PARTUUID=.*$|rootdev=UUID=${root_uuid}|" "${arm_env}" || return 1
    else
        printf '\nrootdev=UUID=%s\n' "${root_uuid}" >> "${arm_env}" || return 1
    fi
}

ab_write_target_boot_itb() {
    local image="$1" target="$2" target_slot="$3"
    local expected_partlabel image_size target_size partlabel

    case "${target_slot}" in
        a|b) ;;
        *) error_exit "Invalid target slot for FIT boot image: ${target_slot}" ;;
    esac

    [ -f "${image}" ] || error_exit "Missing FIT boot payload: ${image}"
    [ -b "${target}" ] || error_exit "FIT boot target is not a block device: ${target}"

    expected_partlabel="$(ab_get_slot_boot_partlabel "${target_slot}")" ||
        error_exit "Invalid target slot for FIT boot image: ${target_slot}"
    partlabel="$(blkid -s PARTLABEL -o value "${target}" 2>/dev/null || true)"
    [ "${partlabel}" = "${expected_partlabel}" ] ||
        error_exit "Refusing to write FIT boot image to ${target}: expected PARTLABEL=${expected_partlabel}, found ${partlabel:-<empty>}"

    ota_is_fit_image "${image}" || error_exit "Refusing to write invalid FIT boot image: ${image}"

    image_size="$(stat -c '%s' "${image}" 2>/dev/null || true)"
    target_size="$(blockdev --getsize64 "${target}" 2>/dev/null || true)"
    [ -n "${image_size}" ] && [ -n "${target_size}" ] && [ "${image_size}" -le "${target_size}" ] ||
        error_exit "FIT boot image size check failed: image=${image_size:-unknown}, target=${target_size:-unknown}"

    log_info "Writing FIT boot image ${image} (${image_size} bytes) to target slot ${target_slot}: ${target}"
    dd if="${image}" of="${target}" bs=4M conv=fsync ||
        error_exit "Failed to write FIT boot image to ${target}"
    sync
}

ab_update_target_bootfs() {
    local temp_work="$1"
    local target_boot_dev="$2"
    local target_root_type="$3"
    local target_root_uuid="$4"
    local boot_mnt arm_env

    boot_mnt="$(make_ota_work_dir "ab-boot-mnt")"
    if ! mount -t ext4 -o rw "${target_boot_dev}" "${boot_mnt}"; then
        log_error "Failed to mount target boot partition"
        rm -rf "${boot_mnt}"
        return 1
    fi

    if [ -f "${temp_work}/${OTA_PAYLOAD_BOOT_TAR}" ]; then
        empty_mount_dir "${boot_mnt}" || {
            log_error "Failed to clear target boot partition"
            umount "${boot_mnt}" 2>/dev/null || log_warn "Failed to unmount target boot partition after clear failure"
            if ! mountpoint -q "${boot_mnt}" 2>/dev/null; then rm -rf "${boot_mnt}"; fi
            return 1
        }
        ab_extract_tar_gz_payload "${temp_work}/${OTA_PAYLOAD_BOOT_TAR}" "${boot_mnt}" "boot" || {
            log_error "Failed to extract boot payload"
            umount "${boot_mnt}" 2>/dev/null || log_warn "Failed to unmount target boot partition after extraction failure"
            if ! mountpoint -q "${boot_mnt}" 2>/dev/null; then rm -rf "${boot_mnt}"; fi
            return 1
        }
        sync
    fi

    arm_env="${boot_mnt}/armbianEnv.txt"
    if ! ab_update_armbian_env "${arm_env}" "${target_root_type}" "${target_root_uuid}"; then
        log_error "Failed to update target boot environment"
        umount "${boot_mnt}" 2>/dev/null || log_warn "Failed to unmount target boot partition after environment update failure"
        if ! mountpoint -q "${boot_mnt}" 2>/dev/null; then rm -rf "${boot_mnt}"; fi
        return 1
    fi
    if ! umount "${boot_mnt}"; then
        log_error "Failed to unmount target boot partition"
        return 1
    fi
    rm -rf "${boot_mnt}"
}

ab_update_target_root_boot_env() {
    local root_mnt="$1"
    local target_root_type="$2"
    local target_root_uuid="$3"
    local arm_env="${root_mnt}/boot/armbianEnv.txt"

    [ -f "${arm_env}" ] || return 0
    ab_update_armbian_env "${arm_env}" "${target_root_type}" "${target_root_uuid}" || {
        log_error "Failed to update target root boot environment"
        return 1
    }
}

ab_update_target_boot() {
    local temp_work="$1"
    local root_mnt="$2"
    local target_boot_dev="$3"
    local target_slot="$4"
    local target_root_type="$5"
    local target_root_uuid="$6"

    if [ -f "${temp_work}/${OTA_PAYLOAD_BOOT_ITB}" ]; then
        [ -n "${target_boot_dev}" ] || error_exit "Cannot find target boot partition for FIT boot image"
        ab_write_target_boot_itb "${temp_work}/${OTA_PAYLOAD_BOOT_ITB}" "${target_boot_dev}" "${target_slot}"
        ab_update_target_root_boot_env "${root_mnt}" "${target_root_type}" "${target_root_uuid}"
    elif [ -n "${target_boot_dev}" ] && [ -b "${target_boot_dev}" ]; then
        ab_update_target_bootfs "${temp_work}" "${target_boot_dev}" "${target_root_type}" "${target_root_uuid}"
    else
        ab_update_target_root_boot_env "${root_mnt}" "${target_root_type}" "${target_root_uuid}"
    fi
}

ab_update_target_filesystem_config() {
    local root_mnt="$1"
    local target_root_label="$2"
    local target_boot_label="$3"
    local target_root_type="$4"
    local target_root_uuid="$5"
    local target_boot_uuid="$6"
    local fstab="${root_mnt}/etc/fstab"
    local crypttab="${root_mnt}/etc/crypttab"
    local existing_root_uuid existing_boot_uuid

    if [ -f "${fstab}" ]; then
        cp "${fstab}" "${fstab}.ota-backup" || return 1
        existing_root_uuid="$(grep -m1 'UUID=[0-9a-f-]*[[:space:]][[:space:]]*/[[:space:]]' "${fstab}" | sed -n 's/.*UUID=\([0-9a-f-]*\).*/\1/p')"
        existing_boot_uuid="$(grep -m1 'UUID=[0-9a-f-]*[[:space:]][[:space:]]*/boot[[:space:]]' "${fstab}" | sed -n 's/.*UUID=\([0-9a-f-]*\).*/\1/p')"

        if [ "${target_root_type}" = "crypto_LUKS" ]; then
            sed -i -E 's|^UUID=[^[:space:]]+[[:space:]]+/[[:space:]]+|/dev/mapper/armbian-root / |' "${fstab}" || return 1
            sed -i -E 's|^/dev/[^[:space:]]+[[:space:]]+/[[:space:]]+|/dev/mapper/armbian-root / |' "${fstab}" || return 1
        elif [ -n "${existing_root_uuid}" ] && [ -n "${target_root_uuid}" ]; then
            sed -i "s|UUID=${existing_root_uuid}|UUID=${target_root_uuid}|g" "${fstab}" || return 1
        fi
        if [ -n "${existing_boot_uuid}" ] && [ -n "${target_boot_uuid}" ]; then
            sed -i "s|UUID=${existing_boot_uuid}|UUID=${target_boot_uuid}|g" "${fstab}" || return 1
        fi

        sed -i "s|LABEL=${ROOT_A_LABEL}|LABEL=${target_root_label}|g" "${fstab}" || return 1
        sed -i "s|LABEL=${ROOT_B_LABEL}|LABEL=${target_root_label}|g" "${fstab}" || return 1
        sed -i "s|LABEL=${BOOT_A_LABEL}|LABEL=${target_boot_label}|g" "${fstab}" || return 1
        sed -i "s|LABEL=${BOOT_B_LABEL}|LABEL=${target_boot_label}|g" "${fstab}" || return 1
    fi

    if [ "${target_root_type}" = "crypto_LUKS" ] && [ -f "${crypttab}" ] && [ -n "${target_root_uuid}" ]; then
        sed -i -E "s|^(armbian-root[[:space:]]+)UUID=[0-9a-fA-F-]+|\\1UUID=${target_root_uuid}|" "${crypttab}" || return 1
    fi
}

ab_cleanup_target_root() {
    local root_mnt="$1"
    local luks_mapper="$2"
    local luks_opened="$3"
    local cleanup_failed=0

    if mountpoint -q "${root_mnt}" 2>/dev/null && ! umount "${root_mnt}"; then
        log_warn "Failed to unmount target root partition"
        cleanup_failed=1
    fi
    if [ "${luks_opened}" -eq 1 ] && [ -n "${luks_mapper}" ] && ! cryptsetup luksClose "${luks_mapper}" >/dev/null 2>&1; then
        log_warn "Failed to close mapper ${luks_mapper}"
        cleanup_failed=1
    fi
    if ! mountpoint -q "${root_mnt}" 2>/dev/null; then
        rm -rf "${root_mnt}" || cleanup_failed=1
    fi

    return "${cleanup_failed}"
}

ab_update_target_partition() {
    local temp_work="$1"
    local target_root_label="$2"
    local target_boot_label="$3"
    local package_path="$4"
    local current_slot="$5"
    local target_slot target_root_dev target_boot_dev root_mnt
    local target_root_uuid target_boot_uuid
    local target_root_type target_root_mount_dev target_root_luks_uuid
    local security_dev key_file luks_mapper luks_opened

    target_slot="$(ab_get_slot_by_label "${target_root_label}")" ||
        error_exit "Invalid target root partition label: ${target_root_label}"
    target_root_dev="$(ab_get_part_by_label "${target_root_label}")"
    target_boot_dev="$(ab_get_part_by_label "${target_boot_label}")"
    [ -n "${target_root_dev}" ] || error_exit "Cannot find target root partition: ${target_root_label}"

    target_root_type="$(blkid -o value -s TYPE "${target_root_dev}" 2>/dev/null || true)"
    target_root_mount_dev="${target_root_dev}"
    target_root_luks_uuid=""
    security_dev=""
    key_file=""
    luks_mapper=""
    luks_opened=0

    if [ "${target_root_type}" = "crypto_LUKS" ]; then
        command -v cryptsetup >/dev/null 2>&1 || error_exit "cryptsetup is required for encrypted AB OTA target partition"
        security_dev="$(ab_get_security_part)"
        [ -n "${security_dev}" ] || error_exit "Security partition not found for encrypted AB OTA"

        key_file="$(make_ota_temp_file "ab-key")"
        if ! ab_get_security_passphrase_file "${key_file}"; then
            rm -f "${key_file}" 2>/dev/null || true
            error_exit "Failed to obtain decryption passphrase from security flow (${security_dev})"
        fi

        luks_mapper="armbian-ota-root-${target_slot}"
        if [ -e "/dev/mapper/${luks_mapper}" ]; then
            cryptsetup luksClose "${luks_mapper}" >/dev/null 2>&1 || true
        fi
        cat "${key_file}" | cryptsetup luksOpen "${target_root_dev}" "${luks_mapper}" ||
            cryptsetup luksOpen "${target_root_dev}" "${luks_mapper}" --key-file "${key_file}" ||
            { rm -f "${key_file}" 2>/dev/null || true; error_exit "Failed to unlock encrypted target root ${target_root_dev}"; }
        rm -f "${key_file}" 2>/dev/null || true
        key_file=""

        target_root_mount_dev="/dev/mapper/${luks_mapper}"
        target_root_luks_uuid="$(blkid -s UUID -o value "${target_root_dev}" 2>/dev/null || true)"
        luks_opened=1
        log_info "Encrypted target slot ${target_slot}: root=${target_root_dev} mapper=${target_root_mount_dev}"
    else
        log_info "Updating slot ${target_slot}: root=${target_root_dev} boot=${target_boot_dev:-<none>}"
    fi

    root_mnt="$(make_ota_work_dir "ab-root-mnt")"
    mount -t ext4 -o rw "${target_root_mount_dev}" "${root_mnt}" || {
        ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
        error_exit "Failed to mount target root partition"
    }

    ab_apply_target_rootfs "${temp_work}" "${root_mnt}" "${package_path}" "${current_slot}" "${target_slot}" || {
        ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
        error_exit "Failed to apply rootfs payload"
    }

    if [ "${target_root_type}" = "crypto_LUKS" ]; then
        target_root_uuid="${target_root_luks_uuid}"
    else
        target_root_uuid="$(ab_get_uuid_by_label "${target_root_label}")"
    fi
    target_boot_uuid="$(ab_get_uuid_by_label "${target_boot_label}")"
    ab_update_target_boot "${temp_work}" "${root_mnt}" "${target_boot_dev}" "${target_slot}" "${target_root_type}" "${target_root_uuid}" || {
        ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
        error_exit "Failed to update target boot partition"
    }
    ab_update_target_filesystem_config "${root_mnt}" "${target_root_label}" "${target_boot_label}" "${target_root_type}" "${target_root_uuid}" "${target_boot_uuid}" || {
        ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
        error_exit "Failed to update target filesystem configuration"
    }

    sync
    ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" ||
        error_exit "Failed to clean up target root partition"
}
