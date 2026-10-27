# Recovery partition layout and policy

function extension_prepare_config__install_recovery_ota() {
    ota_install_overlayroot_dependencies
}

function pre_prepare_partitions__recovery_ota() {
    ota_require_gpt_partition_table "Recovery OTA" || return 1

    USE_HOOK_FOR_PARTITION="yes"
    ROOTFS_TYPE="ext4"
    ROOT_FS_LABEL="armbi_root"

    # Recovery images always carry a dedicated /boot partition so that U-Boot
    # reads boot files (armbianEnv.txt, Image, uInitrd, dtb) directly from a
    # plain ext4 partition instead of the overlayfs-backed rootfs lower layer.
    # At runtime the boot partition is mounted on top of overlayfs via fstab,
    # which makes runtime /boot writes (apt kernel upgrades, manual tweaks,
    # armbian-ota tooling) visible to U-Boot on the next boot.
    #
    # Raw boot mode (secure boot, BOOT_RAW_MODE=yes) keeps using a raw FIT
    # partition; rk-secure-boot.sh clears `bootpart` after partition creation
    # so Armbian's standard mkfs/mount path is skipped for it.
    if ! ota_raw_boot_enabled; then
        BOOTPART_REQUIRED="yes"
        BOOTFS_TYPE="ext4"
        BOOT_FS_LABEL="armbi_boot"
        # Boot size precedence: OTA_BOOT_SIZE > BOOTSIZE > 512. OTA_BOOT_SIZE
        # is only computed later (ota_get_default_partition_sizes needs
        # rootfs_size), so only an explicit env value is visible here; the
        # inline 512 keeps Armbian core from filling its own 256 MiB default.
        # Keep in sync with ota_get_default_partition_sizes().
        BOOTSIZE="${OTA_BOOT_SIZE:-${BOOTSIZE:-512}}"
    fi

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
    # Recovery always reserves space for a boot partition (ext4 for plain /
    # auto-decrypt modes, raw FIT for secure boot).
    boot_size=${BOOTSIZE:-${OTA_BOOT_SIZE}}

    FIXED_IMAGE_SIZE=$((OFFSET + boot_size + security_size + OTA_ROOTFS_SIZE + OTA_USERDATA_SIZE))
    display_alert "Recovery OTA" "Setting FIXED_IMAGE_SIZE=${FIXED_IMAGE_SIZE} MiB (boot=${boot_size} MiB, rootfs=${OTA_ROOTFS_SIZE} MiB, userdata=${OTA_USERDATA_SIZE} MiB)" "info"
}

function create_partition_table__recovery_ota() {
    local next=${OFFSET}
    local p_index=1
    local boot_index rootfs_index userdata_index security_index
    local script="label: ${IMAGE_PARTITION_TABLE:-gpt}\n"
    local data_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    script+="table-length: ${RECOVERY_GPT_TABLE_LENGTH:-64}\n"

    # Boot partition always leads the table. For BOOT_RAW_MODE=yes (secure
    # boot) it carries the raw FIT image; otherwise Armbian's standard boot
    # partition handling (partitioning.sh) formats it as ext4 with label
    # armbi_boot and mounts it at $MOUNT/boot.
    ota_partition_append boot_index "boot" "${BOOTSIZE:-${OTA_BOOT_SIZE}}" "${data_type}"
    bootpart=${boot_index}

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

# Seed the firstboot rollback net at build time (design 3.4, amended after
# on-board validation 2026-10-27): userdata/ota-recovery/backup/ ships a
# boot-only payload plus a BACKUP_PARTIAL=1 transaction state. The original
# firstboot systemd service lost the race against the first-login writers in
# /boot (armbianEnv.txt sed -i rename at 09:18:58, boot.scr/.dist refresh at
# 09:27, a full update-initramfs at 09:29) and against the userdata resize;
# the build-time partition is quiescent by construction and its boot content
# is already final.
function ota_recovery_seed_userdata_partition() {
    local seed_dir="$1"
    local userdata_dev="${LOOP}p${RECOVERY_USERDATA_PART_INDEX}"
    local mapper_name="armbian-recovery-userdata-seed"
    local mount_dev="${userdata_dev}"
    local opened="no"
    local mnt="${seed_dir}/ud_mount"

    check_loop_device "${userdata_dev}"
    [[ -b "${userdata_dev}" ]] || {
        display_alert "Recovery OTA backup seed" "userdata device missing: ${userdata_dev}" "err"
        return 1
    }

    # Encrypted-recovery builds carry userdata inside a LUKS container the
    # format hook closed again; re-open with the build passphrase.
    if ota_encrypted_rootfs_enabled; then
        [[ -n "${CRYPTROOT_PASSPHRASE}" ]] || {
            display_alert "Recovery OTA backup seed" "CRYPTROOT_PASSPHRASE required" "err"
            return 1
        }
        cryptsetup luksClose "${mapper_name}" 2>/dev/null || true
        printf '%s' "${CRYPTROOT_PASSPHRASE}" | run_host_command_logged cryptsetup luksOpen "${userdata_dev}" "${mapper_name}" - || {
            display_alert "Recovery OTA backup seed" "luksOpen failed: ${userdata_dev}" "err"
            return 1
        }
        mount_dev="/dev/mapper/${mapper_name}"
        opened="yes"
    fi

    mkdir -p "${mnt}"
    if ! run_host_command_logged mount "${mount_dev}" "${mnt}"; then
        display_alert "Recovery OTA backup seed" "mount failed: ${mount_dev}" "err"
        [[ "${opened}" == "yes" ]] && cryptsetup luksClose "${mapper_name}" 2>/dev/null || true
        return 1
    fi

    local rc=0
    mkdir -p "${mnt}/ota-recovery/backup" "${mnt}/ota-recovery/state" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        cp "${seed_dir}"/boot.* "${mnt}/ota-recovery/backup/" || rc=$?
    fi
    if [[ "${rc}" -eq 0 ]]; then
        cat > "${mnt}/ota-recovery/state/ota-state.env" <<'STATE' || rc=$?
# Armbian OTA runtime state
OTA_MODE=recovery
STATUS=success
PACKAGE_PATH=
CURRENT_SLOT=
TARGET_SLOT=
START_TIME=
COMPLETE_TIME=
RETRY_COUNT=0
ERROR_MSG=
BACKUP_PARTIAL=1
STATE
    fi
    sync
    run_host_command_logged umount "${mnt}" || display_alert "Recovery OTA backup seed" "umount ${mnt} failed" "warn"
    [[ "${opened}" == "yes" ]] && cryptsetup luksClose "${mapper_name}" 2>/dev/null || true

    [[ "${rc}" -eq 0 ]] || {
        display_alert "Recovery OTA backup seed" "failed to seed userdata" "err"
        return 1
    }
    display_alert "Recovery OTA backup seed" "boot-only backup + BACKUP_PARTIAL=1 written to ${mount_dev}" "info"
    return 0
}

function pre_umount_final_image__905_recovery_seed_userdata_backup() {
    [[ "${OTA_ENABLE:-}" == "yes" && "${AB_PART_OTA:-no}" != "yes" ]] || return 0
    [[ -n "${RECOVERY_USERDATA_PART_INDEX:-}" ]] || {
        display_alert "Recovery OTA backup seed" "no userdata partition, skipping" "warn"
        return 0
    }
    if [[ "${OTA_KEEP_BACKUP:-yes}" == "no" ]]; then
        display_alert "Recovery OTA backup seed" "OTA_KEEP_BACKUP=no, no rollback net" "info"
        return 0
    fi
    [[ -b "${LOOP}" ]] || {
        display_alert "Recovery OTA backup seed" "loop device missing: ${LOOP}" "err"
        return 1
    }

    local seed_dir="${WORKDIR}/ota_userdata_seed_$$"
    rm -rf "${seed_dir}"
    mkdir -p "${seed_dir}" || return 1

    # Boot payload source mirrors the OTA package choices
    # (ota_create_payload_archives): raw FIT image for secure boot, an
    # archive of the ext4 boot partition otherwise.
    if ota_secure_boot_encrypted_rootfs_enabled; then
        ota_copy_secure_boot_itb "${seed_dir}" || {
            rm -rf "${seed_dir}"
            return 1
        }
    else
        local boot_partition=""
        ota_resolve_boot_partition "plain" boot_partition
        if [[ -z "${boot_partition}" ]]; then
            display_alert "Recovery OTA backup seed" "boot partition not found" "err"
            rm -rf "${seed_dir}"
            return 1
        fi
        # ota_archive_boot_partition mounts the source at the given dir,
        # which must exist beforehand.
        mkdir -p "${seed_dir}/boot_mount"
        ota_archive_boot_partition "${boot_partition}" "${seed_dir}/boot_mount" \
            "${seed_dir}/boot.${OTA_PAYLOAD_TAR_SUFFIX}" "${seed_dir}/boot.sha256" \
            "boot partition" "err" || {
            rm -rf "${seed_dir}"
            return 1
        }
    fi

    local rc=0
    ota_recovery_seed_userdata_partition "${seed_dir}" || rc=$?
    rm -rf "${seed_dir}"
    return "${rc}"
}
