# Recovery OTA partition helpers

function ota_recovery_enabled() {
    [[ "${OTA_ENABLE}" == "yes" && "${AB_PART_OTA}" != "yes" ]]
}

function ota_recovery_encrypted_rootfs_enabled() {
    ota_recovery_enabled && ota_encrypted_rootfs_enabled
}

function ota_recovery_set_partition_sizes() {
    RECOVERY_USERDATA_SIZE=${RECOVERY_USERDATA_SIZE:-1024}

    [[ "${RECOVERY_USERDATA_SIZE}" =~ ^[0-9]+$ && "${RECOVERY_USERDATA_SIZE}" -gt 0 ]] ||
        exit_with_error "Invalid RECOVERY_USERDATA_SIZE" "${RECOVERY_USERDATA_SIZE}"
}

function ota_recovery_prepare_image_size() {
    local rootfs_overhead_mib security_size boot_size

    ota_recovery_set_partition_sizes

    if [[ -z "${RECOVERY_ROOTFS_SIZE:-}" ]]; then
        # Match the normal Armbian CLI image sizing policy (30% headroom), but
        # make the rootfs size explicit so userdata can be the final partition.
        RECOVERY_ROOTFS_SIZE=$(((rootfs_size * 130 + 99) / 100))
    fi
    [[ "${RECOVERY_ROOTFS_SIZE}" =~ ^[0-9]+$ && "${RECOVERY_ROOTFS_SIZE}" -gt "${rootfs_size}" ]] ||
        exit_with_error "Invalid RECOVERY_ROOTFS_SIZE" "${RECOVERY_ROOTFS_SIZE:-unset}; rootfs requires more than ${rootfs_size} MiB"

    rootfs_overhead_mib=${EXTRA_ROOTFS_MIB_SIZE:-0}
    security_size=0
    ota_recovery_encrypted_rootfs_enabled && security_size=${SECURE_STORAGE_SECURITY_SIZE:-4}
    boot_size=0
    if [[ "${BOOTSIZE:-0}" =~ ^[0-9]+$ ]]; then
        boot_size=${BOOTSIZE}
    fi

    FIXED_IMAGE_SIZE=$((OFFSET + UEFISIZE + boot_size + RECOVERY_ROOTFS_SIZE + RECOVERY_USERDATA_SIZE + rootfs_overhead_mib + security_size))
    display_alert "Recovery OTA" "Setting FIXED_IMAGE_SIZE=${FIXED_IMAGE_SIZE} MiB (rootfs=${RECOVERY_ROOTFS_SIZE} MiB, userdata=${RECOVERY_USERDATA_SIZE} MiB)" "info"
}

function ota_recovery_append_partition() {
    local index_var="$1"
    local name="$2"
    local size="$3"
    local type="$4"

    printf -v "${index_var}" '%s' "${p_index}"
    script+="${p_index} : name=\"${name}\", start=${next}MiB, size=${size}MiB, type=${type}\n"
    next=$((next + size))
    p_index=$((p_index + 1))
}

function extension_prepare_config__install_recovery_userdata_tools() {
    if ota_recovery_enabled; then
        add_packages_to_image busybox-static
    fi
}

function pre_prepare_partitions__recovery_userdata() {
    if ! ota_recovery_enabled; then
        return 0
    fi

    ota_recovery_set_partition_sizes
    if ota_recovery_encrypted_rootfs_enabled; then
        display_alert "Recovery OTA" "Creating encrypted rootfs and userdata partitions" "info"
        return 0
    fi

    USE_HOOK_FOR_PARTITION="yes"
    ROOTFS_TYPE="ext4"
    ROOT_FS_LABEL="armbi_root"
    display_alert "Recovery OTA" "Creating rootfs and userdata partitions" "info"
}

function prepare_image_size__recovery_userdata() {
    ota_recovery_enabled || return 0
    ota_recovery_prepare_image_size
}

function create_partition_table__recovery_userdata() {
    if ! ota_recovery_enabled || ota_recovery_encrypted_rootfs_enabled; then
        return 0
    fi

    local next=${OFFSET}
    local p_index=1
    local unused_index rootfs_index userdata_index
    local script="label: ${IMAGE_PARTITION_TABLE:-gpt}\n"
    local root_type="${PARTITION_TYPE_UUID_ROOT:-0FC63DAF-8483-4772-8E79-3D69D8477DE4}"
    local boot_type="BC13C2FF-59E6-4262-A352-B275FD6F7172"

    if [[ "${IMAGE_PARTITION_TABLE:-gpt}" == "gpt" ]]; then
        script+="table-length: ${RECOVERY_GPT_TABLE_LENGTH:-64}\n"
    else
        root_type="83"
        boot_type="ea"
    fi

    if [[ -n "${BIOSSIZE}" && "${BIOSSIZE}" -gt 0 ]]; then
        ota_recovery_append_partition unused_index "bios" "${BIOSSIZE}" "21686148-6449-6E6F-744E-656564454649"
    fi
    if [[ -n "${UEFISIZE}" && "${UEFISIZE}" -gt 0 ]]; then
        ota_recovery_append_partition unused_index "efi" "${UEFISIZE}" "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
    fi
    if [[ "${BOOTSIZE:-0}" -gt 0 && ( -n "${BOOTFS_TYPE}" || "${BOOTPART_REQUIRED}" == "yes" ) ]]; then
        ota_recovery_append_partition unused_index "boot" "${BOOTSIZE}" "${boot_type}"
        bootpart=${unused_index}
    fi

    ota_recovery_append_partition rootfs_index "rootfs" "${RECOVERY_ROOTFS_SIZE}" "${root_type}"
    ota_recovery_append_partition userdata_index "userdata" "${RECOVERY_USERDATA_SIZE}" "${root_type}"

    display_alert "Recovery OTA" "Custom recovery partition table:\n${script}" "debug"
    printf "%b" "${script}" | run_host_command_logged sfdisk "${SDCARD}.raw" ||
        exit_with_error "Recovery userdata partition creation failed" "${SDCARD}"

    rootpart=${rootfs_index}
    RECOVERY_USERDATA_PART_INDEX=${userdata_index}
}

function ota_recovery_format_userdata() {
    local userdata_dev="${LOOP}p${RECOVERY_USERDATA_PART_INDEX}"

    check_loop_device "${userdata_dev}"
    if ota_recovery_encrypted_rootfs_enabled; then
        [[ -n "${CRYPTROOT_PASSPHRASE}" ]] ||
            exit_with_error "CRYPTROOT_PASSPHRASE is required for encrypted recovery userdata"
        printf "%s" "${CRYPTROOT_PASSPHRASE}" | run_host_command_logged cryptsetup luksFormat ${CRYPTROOT_PARAMETERS} "${userdata_dev}" - ||
            exit_with_error "Failed to luksFormat recovery userdata" "${userdata_dev}"
        printf "%s" "${CRYPTROOT_PASSPHRASE}" | run_host_command_logged cryptsetup luksOpen "${userdata_dev}" armbian-recovery-userdata-build - ||
            exit_with_error "Failed to unlock recovery userdata" "${userdata_dev}"
        run_host_command_logged mkfs.ext4 -q -L armbi_usrdata /dev/mapper/armbian-recovery-userdata-build || {
            run_host_command_logged cryptsetup luksClose armbian-recovery-userdata-build || true
            exit_with_error "Failed to format encrypted recovery userdata" "${userdata_dev}"
        }
        run_host_command_logged cryptsetup luksClose armbian-recovery-userdata-build ||
            exit_with_error "Failed to close encrypted recovery userdata" "${userdata_dev}"
    else
        run_host_command_logged mkfs.ext4 -q -L armbi_usrdata "${userdata_dev}" ||
            exit_with_error "Failed to format recovery userdata" "${userdata_dev}"
    fi
}

function format_partitions__recovery_userdata() {
    if ota_recovery_enabled && [[ -n "${RECOVERY_USERDATA_PART_INDEX:-}" ]]; then
        ota_recovery_format_userdata
    fi
}
