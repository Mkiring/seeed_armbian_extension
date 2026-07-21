#!/bin/bash

AB_OTA_ROOTFS_TAR="rootfs.tar.gz"
AB_OTA_BOOT_TAR="boot.tar.gz"
AB_OTA_BOOT_ITB="boot.itb"
AB_OTA_ROOTFS_SHA="rootfs.sha256"
AB_OTA_BOOT_SHA="boot.sha256"

BOOT_A_LABEL="armbi_boota"
BOOT_B_LABEL="armbi_bootb"
ROOT_A_LABEL="armbi_roota"
ROOT_B_LABEL="armbi_rootb"

AB_ENV_LIB="${OTA_RUNTIME_DIR}/ab-env.sh"
[ -r "${AB_ENV_LIB}" ] || {
    echo "ERROR: A/B U-Boot environment helper not found: ${AB_ENV_LIB}" >&2
    return 1
}
. "${AB_ENV_LIB}"

AB_SECURITY_LIB="${OTA_RUNTIME_DIR}/ab-security.sh"
[ -r "${AB_SECURITY_LIB}" ] || {
    echo "ERROR: A/B security helper not found: ${AB_SECURITY_LIB}" >&2
    return 1
}
. "${AB_SECURITY_LIB}"

# Slot helpers
ab_get_current_slot() {
    local current_slot

    current_slot="$(ab_env_current_slot 2>/dev/null || true)"
    if [ -n "${current_slot}" ]; then
        echo "${current_slot}"
        return 0
    fi

    current_slot="$(ab_env_get "boot_slot")"
    case "${current_slot}" in
        a|b) echo "${current_slot}" ;;
        *) echo "a" ;;
    esac
}

ab_get_target_slot() {
    if [ "$(ab_get_current_slot)" = "a" ]; then
        echo "b"
    else
        echo "a"
    fi
}

ab_get_slot_boot_label() {
    if [ "$1" = "a" ]; then
        echo "${BOOT_A_LABEL}"
    else
        echo "${BOOT_B_LABEL}"
    fi
}

ab_get_slot_root_label() {
    if [ "$1" = "a" ]; then
        echo "${ROOT_A_LABEL}"
    else
        echo "${ROOT_B_LABEL}"
    fi
}

ab_slot_from_root_label() {
    case "$1" in
        "${ROOT_A_LABEL}") echo "a" ;;
        "${ROOT_B_LABEL}") echo "b" ;;
        *) echo "" ;;
    esac
}

# U-Boot environment validation
ab_require_tools() {
    ota_require_runtime fw_printenv fw_setenv blkid mount umount mountpoint tar findmnt sed grep awk reboot dd od tr blockdev
}

ab_env_slot_boot_ready() {
    local bootcmd scan preboot devtype devnum part_a part_b boot_mode fit_selector
    bootcmd="$(ab_env_get bootcmd)"
    scan="$(ab_env_get scan_dev_for_boot_part)"
    preboot="$(ab_env_get ab_preboot)"
    devtype="$(ab_env_get ab_boot_devtype)"
    devnum="$(ab_env_get ab_boot_devnum)"
    part_a="$(ab_env_get distro_bootpart_a)"
    part_b="$(ab_env_get distro_bootpart_b)"
    boot_mode="$(ab_env_get ab_boot_mode)"
    fit_selector="$(ab_env_get ab_select_fit_slot)"

    [ -n "${devtype}" ] || return 1
    [ -n "${devnum}" ] || return 1
    [ -n "${part_a}" ] || return 1
    [ -n "${part_b}" ] || return 1
    echo "${preboot}" | grep -q "slot_retry_left" || return 1
    echo "${preboot}" | grep -q "ota_in_progress" || return 1

    if [ "${boot_mode}" = "raw-fit" ]; then
        echo "${fit_selector}" | grep -q "boot_fit_part" || return 1
        echo "${bootcmd}" | grep -q "run ab_select_fit_slot" || return 1
        echo "${bootcmd}" | grep -q "boot_fit" || return 1
        return 0
    fi

    echo "${scan}" | grep -q "ab_boot_devtype" || return 1
    echo "${scan}" | grep -q "boot_slot" || return 1
    echo "${bootcmd}" | grep -q "run ab_preboot" || return 1
    echo "${bootcmd}" | grep -q "run distro_bootcmd" || return 1
    return 0
}

ab_ensure_slot_boot_env() {
    local init_script
    init_script="/usr/lib/armbian/armbian-ota-init-uboot"

    if ab_env_slot_boot_ready; then
        return 0
    fi

    [ -x "${init_script}" ] || error_exit "AB boot env is not initialized and ${init_script} is missing"
    log_warn "AB boot env is incomplete, trying to repair via ${init_script} --force"
    "${init_script}" --force || error_exit "Failed to reinitialize AB boot env"
    ab_env_slot_boot_ready || error_exit "AB boot env is still invalid after reinitialization"
}

ab_require_partition_label() {
    local label="$1"
    local dev

    dev="$(ab_get_part_by_label "${label}")"
    [ -n "${dev}" ] || error_exit "AB OTA requires partition label ${label}, but it was not found"
}

ab_validate_environment() {
    local current_slot

    ab_ensure_slot_boot_env
    ab_require_partition_label "${BOOT_A_LABEL}"
    ab_require_partition_label "${BOOT_B_LABEL}"
    ab_require_partition_label "${ROOT_A_LABEL}"
    ab_require_partition_label "${ROOT_B_LABEL}"

    current_slot="$(ab_env_current_slot 2>/dev/null || true)"
    case "${current_slot}" in
        a|b) ;;
        *) error_exit "Current rootfs is not running from an AB root partition" ;;
    esac
}

# Payload verification and extraction
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

ab_is_fit_image() {
    local image="$1" magic

    [ -f "${image}" ] || return 1
    magic="$(dd if="${image}" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "${magic}" = "d00dfeed" ]
}

ab_verify_payload() {
    local work_dir="$1"

    [ -f "${work_dir}/${AB_OTA_BOOT_ITB}" ] && [ -f "${work_dir}/${AB_OTA_BOOT_TAR}" ] &&
        error_exit "OTA package contains both ${AB_OTA_BOOT_ITB} and ${AB_OTA_BOOT_TAR}; refusing ambiguous boot payload"

    verify_payload_archives "${work_dir}" \
        "${AB_OTA_ROOTFS_TAR}" "${AB_OTA_ROOTFS_SHA}" \
        "${AB_OTA_BOOT_TAR}" "${AB_OTA_BOOT_SHA}"

    if [ -f "${work_dir}/${AB_OTA_BOOT_ITB}" ]; then
        verify_sha256 "${work_dir}/${AB_OTA_BOOT_ITB}" "${work_dir}/${AB_OTA_BOOT_SHA}" "${AB_OTA_BOOT_ITB}"
        ab_is_fit_image "${work_dir}/${AB_OTA_BOOT_ITB}" ||
            error_exit "Invalid FIT boot image in OTA package: ${AB_OTA_BOOT_ITB}"
    fi
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

# Target slot update helpers
ab_apply_target_rootfs() {
    local temp_work="$1"
    local root_mnt="$2"
    local package_path="$3"
    local current_slot="$4"
    local target_slot="$5"

    empty_mount_dir "${root_mnt}" || return 1
    ab_extract_tar_gz_payload "${temp_work}/${AB_OTA_ROOTFS_TAR}" "${root_mnt}" "rootfs" || return 1

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

    expected_partlabel="boot_${target_slot}"
    partlabel="$(blkid -s PARTLABEL -o value "${target}" 2>/dev/null || true)"
    [ "${partlabel}" = "${expected_partlabel}" ] ||
        error_exit "Refusing to write FIT boot image to ${target}: expected PARTLABEL=${expected_partlabel}, found ${partlabel:-<empty>}"

    ab_is_fit_image "${image}" || error_exit "Refusing to write invalid FIT boot image: ${image}"

    image_size="$(stat -c '%s' "${image}" 2>/dev/null || true)"
    target_size="$(blockdev --getsize64 "${target}" 2>/dev/null || true)"
    [ -n "${image_size}" ] && [ -n "${target_size}" ] && [ "${image_size}" -le "${target_size}" ] ||
        error_exit "FIT boot image size check failed: image=${image_size:-unknown}, target=${target_size:-unknown}"

    log_info "Writing FIT boot image ${image} (${image_size} bytes) to target slot ${target_slot}: ${target}"
    dd if="${image}" of="${target}" bs=4M conv=fsync ||
        error_exit "Failed to write FIT boot image to ${target}"
    sync
}

ab_update_target_boot() {
    local temp_work="$1"
    local root_mnt="$2"
    local target_boot_dev="$3"
    local target_slot="$4"
    local target_root_type="$5"
    local target_root_uuid="$6"
    local boot_mnt arm_env=""

    if [ -f "${temp_work}/${AB_OTA_BOOT_ITB}" ]; then
        [ -n "${target_boot_dev}" ] || error_exit "Cannot find target boot partition for FIT boot image"
        ab_write_target_boot_itb "${temp_work}/${AB_OTA_BOOT_ITB}" "${target_boot_dev}" "${target_slot}"
    elif [ -n "${target_boot_dev}" ] && [ -b "${target_boot_dev}" ]; then
        boot_mnt="$(make_ota_work_dir "ab-boot-mnt")"
        if mount -t ext4 -o rw "${target_boot_dev}" "${boot_mnt}"; then
            if [ -f "${temp_work}/${AB_OTA_BOOT_TAR}" ]; then
                empty_mount_dir "${boot_mnt}" || {
                    log_error "Failed to clear target boot partition"
                    umount "${boot_mnt}" 2>/dev/null || \
                        log_warn "Failed to unmount target boot partition after clear failure"
                    if ! mountpoint -q "${boot_mnt}" 2>/dev/null; then
                        rm -rf "${boot_mnt}"
                    fi
                    return 1
                }
                ab_extract_tar_gz_payload "${temp_work}/${AB_OTA_BOOT_TAR}" "${boot_mnt}" "boot" || \
                    {
                        log_error "Failed to extract boot payload"
                        umount "${boot_mnt}" 2>/dev/null || \
                            log_warn "Failed to unmount target boot partition after extraction failure"
                        if ! mountpoint -q "${boot_mnt}" 2>/dev/null; then
                            rm -rf "${boot_mnt}"
                        fi
                        return 1
                    }
                sync
            fi
            arm_env="${boot_mnt}/armbianEnv.txt"
            if ! ab_update_armbian_env "${arm_env}" "${target_root_type}" "${target_root_uuid}"; then
                log_error "Failed to update target boot environment"
                umount "${boot_mnt}" 2>/dev/null || \
                    log_warn "Failed to unmount target boot partition after environment update failure"
                if ! mountpoint -q "${boot_mnt}" 2>/dev/null; then
                    rm -rf "${boot_mnt}"
                fi
                return 1
            fi
            if ! umount "${boot_mnt}"; then
                log_error "Failed to unmount target boot partition"
                return 1
            fi
        else
            log_error "Failed to mount target boot partition"
            rm -rf "${boot_mnt}"
            return 1
        fi
        rm -rf "${boot_mnt}"
    fi

    if [ -z "${arm_env}" ] && [ -f "${root_mnt}/boot/armbianEnv.txt" ]; then
        ab_update_armbian_env "${root_mnt}/boot/armbianEnv.txt" "${target_root_type}" "${target_root_uuid}" || {
            log_error "Failed to update target root boot environment"
            return 1
        }
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

        sed -i "s|LABEL=armbi_roota|LABEL=${target_root_label}|g" "${fstab}" || return 1
        sed -i "s|LABEL=armbi_rootb|LABEL=${target_root_label}|g" "${fstab}" || return 1
        sed -i "s|LABEL=armbi_boota|LABEL=${target_boot_label}|g" "${fstab}" || return 1
        sed -i "s|LABEL=armbi_bootb|LABEL=${target_boot_label}|g" "${fstab}" || return 1
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
    if [ "${luks_opened}" -eq 1 ] && [ -n "${luks_mapper}" ] && \
        ! cryptsetup luksClose "${luks_mapper}" >/dev/null 2>&1; then
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

    target_slot="$(ab_slot_from_root_label "${target_root_label}")"

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

    ab_apply_target_rootfs "${temp_work}" "${root_mnt}" "${package_path}" \
        "${current_slot}" "${target_slot}" || {
        ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
        error_exit "Failed to apply rootfs payload"
    }

    if [ "${target_root_type}" = "crypto_LUKS" ]; then
        target_root_uuid="${target_root_luks_uuid}"
    else
        target_root_uuid="$(ab_get_uuid_by_label "${target_root_label}")"
    fi
    target_boot_uuid="$(ab_get_uuid_by_label "${target_boot_label}")"
    ab_update_target_boot "${temp_work}" "${root_mnt}" "${target_boot_dev}" \
        "${target_slot}" "${target_root_type}" "${target_root_uuid}" || {
        ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
        error_exit "Failed to update target boot partition"
    }
    ab_update_target_filesystem_config "${root_mnt}" "${target_root_label}" "${target_boot_label}" \
        "${target_root_type}" "${target_root_uuid}" "${target_boot_uuid}" || {
        ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
        error_exit "Failed to update target filesystem configuration"
    }

    sync
    ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || \
        error_exit "Failed to clean up target root partition"
}

# OTA state helpers
ab_record_state() {
    local status="$1"
    local current_slot="$2"
    local target_slot="$3"

    state_mark_mode "ab" || return 1
    state_mark_status "${status}" || return 1
    state_set "CURRENT_SLOT" "${current_slot}" || return 1
    state_set "TARGET_SLOT" "${target_slot}" || return 1
    state_set "COMPLETE_TIME" "$(date -Iseconds)" || return 1
}

ab_mark_ready_to_boot() {
    local package_path="$1"
    local current_slot="$2"
    local target_slot="$3"

    state_mark_prepared "ab" "ready_to_boot" "${package_path}" "${current_slot}" "${target_slot}"
}

# Public A/B OTA commands
ab_start_ota() {
    local package_path="$1"
    local current_slot target_slot target_root_label target_boot_label temp_work

    [ -n "${package_path}" ] || error_exit "Usage: armbian-ota start <ota-package.tar.gz>"
    [ -f "${package_path}" ] || error_exit "OTA package not found: ${package_path}"
    ab_require_tools
    assert_package_mode_matches "${package_path}" "ab"
    ab_validate_environment

    current_slot="$(ab_get_current_slot)"
    target_slot="$(ab_get_target_slot)"
    target_root_label="$(ab_get_slot_root_label "${target_slot}")"
    target_boot_label="$(ab_get_slot_boot_label "${target_slot}")"

    if [ "$(ab_env_get ota_in_progress)" = "1" ]; then
        error_exit "Another AB OTA boot verification is still in progress"
    fi

    temp_work="$(make_ota_work_dir "ab-package")"
    extract_ota_package "${package_path}" "${temp_work}"
    ab_verify_payload "${temp_work}"

    ab_update_target_partition "${temp_work}" "${target_root_label}" "${target_boot_label}" "${package_path}" "${current_slot}"
    rm -rf "${temp_work}"

    ab_mark_ready_to_boot "${package_path}" "${current_slot}" "${target_slot}" ||
        error_exit "Failed to mark AB OTA ready to boot"
    ab_env_prepare "${target_slot}" || error_exit "Failed to prepare U-Boot A/B state"

    log_info "AB OTA staged successfully. Current slot=${current_slot}, target slot=${target_slot}"
    log_info "Reboot to boot the new slot"
}

ab_mark_success() {
    local current_slot
    ab_require_tools

    if [ "$(state_get OTA_MODE)" != "ab" ] && [ "$(ab_env_get ota_in_progress)" != "1" ]; then
        log_info "No A/B OTA in progress, nothing to mark"
        return 0
    fi

    current_slot="$(ab_get_current_slot)"
    ab_env_mark_success "${current_slot}" ||
        error_exit "Failed to mark A/B boot successful"

    ab_record_state "success" "${current_slot}" "" ||
        error_exit "Failed to record successful A/B OTA state"

    log_info "AB OTA marked successful on slot ${current_slot}"
}

ab_rollback() {
    local last_success
    ab_require_tools

    if [ "$(ab_env_get ota_in_progress)" != "1" ]; then
        log_info "No A/B OTA in progress, nothing to rollback"
        return 0
    fi

    last_success="$(ab_env_get boot_success)"
    [ -n "${last_success}" ] || last_success="a"

    ab_env_rollback || error_exit "Failed to restore A/B boot state"

    ab_record_state "rollback" "${last_success}" "" ||
        error_exit "Failed to record A/B rollback state"

    log_info "Rollback configured, rebooting back to slot ${last_success}"
    sync
    reboot
}

ab_switch_slot() {
    local target_slot="$1"
    local current_slot target_boot_label target_root_label

    ab_require_tools
    current_slot="$(ab_get_current_slot)"
    [ -n "${target_slot}" ] || target_slot="$(ab_get_target_slot)"

    case "${target_slot}" in
        a|b) ;;
        *) error_exit "Usage: armbian-ota switch-slot [a|b]" ;;
    esac

    if [ "$(ab_env_get ota_in_progress)" = "1" ]; then
        error_exit "Cannot switch slots while A/B OTA is in progress"
    fi

    target_boot_label="$(ab_get_slot_boot_label "${target_slot}")"
    target_root_label="$(ab_get_slot_root_label "${target_slot}")"
    [ -n "$(ab_get_part_by_label "${target_boot_label}")" ] || error_exit "Cannot find target boot partition: ${target_boot_label}"
    [ -n "$(ab_get_part_by_label "${target_root_label}")" ] || error_exit "Cannot find target root partition: ${target_root_label}"

    if [ "${current_slot}" = "${target_slot}" ]; then
        log_info "Already booting slot ${target_slot}"
        return 0
    fi

    ab_env_mark_success "${target_slot}" || error_exit "Failed to switch A/B boot state"

    ab_record_state "slot_switched" "${current_slot}" "${target_slot}" ||
        error_exit "Failed to record A/B slot switch state"

    log_info "Boot slot switched from ${current_slot} to ${target_slot}; reboot to apply"
}

ab_status() {
    local current_slot ota_in_progress
    current_slot="$(ab_get_current_slot)"
    ota_in_progress="$(ab_env_get ota_in_progress)"

    echo "=== Armbian OTA Status (A/B) ==="
    echo "Mode: ab"
    echo "Status: $(state_get STATUS)"
    echo "Current slot: ${current_slot}"
    echo "Target slot: $(state_get TARGET_SLOT)"
    echo ""
    echo "U-Boot Environment:"
    echo "  boot_slot: $(ab_env_get boot_slot)"
    echo "  boot_success: $(ab_env_get boot_success)"
    echo "  ota_in_progress: ${ota_in_progress}"
    echo "  try_count: $(ab_env_get try_count)"
    echo "  slot_retry_max: $(ab_env_retry_max)"
    echo "  slot_retry_left: $(ab_env_get slot_retry_left)"
    echo ""
    echo "Partitions:"
    for label in "${BOOT_A_LABEL}" "${BOOT_B_LABEL}" "${ROOT_A_LABEL}" "${ROOT_B_LABEL}"; do
        local dev uuid mark slot
        dev="$(ab_get_part_by_label "${label}")"
        uuid=""
        [ -n "${dev}" ] && uuid="$(blkid -s UUID -o value "${dev}" 2>/dev/null | head -n1)"
        mark=""
        slot=""
        case "${label}" in
            "${BOOT_A_LABEL}"|"${ROOT_A_LABEL}") slot="a" ;;
            "${BOOT_B_LABEL}"|"${ROOT_B_LABEL}") slot="b" ;;
        esac
        if [ "${slot}" = "${current_slot}" ]; then
            mark=" [BOOTING]"
        fi
        echo "  ${label}: ${dev:-NOT FOUND} ${uuid:+(UUID: ${uuid})}${mark}"
    done
}
