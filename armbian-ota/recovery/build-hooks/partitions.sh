# Recovery partition layout and policy

function extension_prepare_config__install_recovery_ota() {
    ota_install_overlayroot_dependencies
}

function pre_prepare_partitions__recovery_ota() {
    ota_require_gpt_partition_table "Recovery OTA" || return 1

    USE_HOOK_FOR_PARTITION="yes"
    ROOTFS_TYPE="ext4"
    ROOT_FS_LABEL="armbi_root"
    if ota_encrypted_rootfs_enabled; then
        display_alert "Recovery OTA" "Creating security, encrypted rootfs and userdata partitions" "info"
    else
        display_alert "Recovery OTA" "Creating rootfs and userdata partitions" "info"
    fi
}

function prepare_image_size__recovery_ota() {
    local boot_size=0
    local security_size=0

    ota_get_default_partition_sizes
    ota_encrypted_rootfs_enabled && security_size=${OTA_SECURITY_SIZE}
    if ota_raw_boot_enabled; then
        boot_size=${BOOTSIZE:-${OTA_BOOT_SIZE}}
    fi

    FIXED_IMAGE_SIZE=$((OFFSET + boot_size + security_size + OTA_ROOTFS_SIZE + OTA_USERDATA_SIZE))
    display_alert "Recovery OTA" "Setting FIXED_IMAGE_SIZE=${FIXED_IMAGE_SIZE} MiB (rootfs=${OTA_ROOTFS_SIZE} MiB, userdata=${OTA_USERDATA_SIZE} MiB)" "info"
}

function create_partition_table__recovery_ota() {
    local next=${OFFSET}
    local p_index=1
    local boot_index rootfs_index userdata_index security_index
    local script="label: ${IMAGE_PARTITION_TABLE:-gpt}\n"
    local data_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    script+="table-length: ${RECOVERY_GPT_TABLE_LENGTH:-64}\n"

    if ota_raw_boot_enabled; then
        ota_partition_append boot_index "boot" "${BOOTSIZE:-${OTA_BOOT_SIZE}}" "${data_type}"
        bootpart=${boot_index}
    fi

    if ota_encrypted_rootfs_enabled; then
        ota_partition_append security_index "security" "${OTA_SECURITY_SIZE}" "${data_type}"
    fi

    local root_type="${PARTITION_TYPE_UUID_ROOT:-${data_type}}"
    ota_partition_append rootfs_index "rootfs" "${OTA_ROOTFS_SIZE}" "${root_type}"
    ota_partition_append userdata_index "userdata" "${OTA_USERDATA_SIZE}" "${root_type}"

    display_alert "Recovery OTA" "Custom recovery partition table:\n${script}" "debug"
    printf "%b" "${script}" | run_host_command_logged sfdisk "${SDCARD}.raw" ||
        exit_with_error "Recovery userdata partition creation failed" "${SDCARD}"

    rootpart=${rootfs_index}
    RECOVERY_USERDATA_PART_INDEX=${userdata_index}
    if [[ -n "${security_index:-}" ]]; then
        SECURE_STORAGE_SECURITY_PART_INDEX=${security_index}
    fi
}

function format_partitions__recovery_ota() {
    if [[ -z "${RECOVERY_USERDATA_PART_INDEX:-}" ]]; then
        return 0
    fi

    local userdata_dev="${LOOP}p${RECOVERY_USERDATA_PART_INDEX}"
    if ota_encrypted_rootfs_enabled; then
        ota_partition_format_luks_ext4 "Recovery OTA" "${userdata_dev}" \
            "armbian-recovery-userdata-build" "armbi_usrdata" "userdata"
    else
        ota_partition_format_ext4 "Recovery OTA" "${userdata_dev}" "armbi_usrdata" "userdata"
    fi
}
