#
# Shared Helpers
#

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rk-common.sh"

#
# Source-Time Setup
#

function rk_auto_decryption_enable_optee_bootchain() {
    if [[ "${CRYPTROOT_ENABLE}" != "yes" || "${RK_AUTO_DECRYP}" != "yes" ]]; then
        return 0
    fi

    if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" || "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; then
        return 0
    fi

    display_alert "OP-TEE bootchain" "Enable OP-TEE boot chain for encrypted auto-decryption without secure boot" "info"
    export RK_OPTEE_BOOT_ENABLE=yes
}

rk_auto_decryption_enable_optee_bootchain

#
# Mode And Path Helpers
#

function rk_autodecrypt_nonsecure_mode_enabled() {
    rk_autodecrypt_enabled && ! rk_full_secure_boot_enabled
}

function rk_autodecrypt_resolve_extension_dir() {
    rk_resolve_extension_dir "auto-decryption-config"
}

function rk_autodecrypt_run_host_command() {
    rk_run_host_command "$@"
}

function rk_autodecrypt_ensure_sdk_tools() {
    RK_AUTODECRYPT_SDK_TOOLS="$(rk_sdk_tools_root)"
    rk_ensure_sdk_tools "optee"
}

function rk_autodecrypt_ensure_pycryptodome() {
    if python3 - <<'PY' >/dev/null 2>&1
import Crypto
PY
    then
        return 0
    fi

    rk_autodecrypt_run_host_command apt-get install -y python3-pycryptodome ||
        exit_with_error "failed to install python3-pycryptodome" "apt-get"
}

#
# U-Boot Defconfig Helpers
#

function rk_autodecrypt_detect_vendor_board() {
    if [[ -n "${UBOOT_VENDOR_BOARD}" ]]; then
        echo "${UBOOT_VENDOR_BOARD}"
        return 0
    fi

    local detected_board
    detected_board="$(rk_detect_vendor_board)"
    if [[ -n "${detected_board}" && "${detected_board}" != "unknown" ]]; then
        echo "${detected_board}"
        return 0
    fi

    echo "unknown"
}

function rk_autodecrypt_copy_secure_boot_defconfig() {
    local vendor_board="$1"
    local target_defconfig="configs/${vendor_board}_defconfig"
    local extension_dir candidate src_defconfig

    extension_dir="$(rk_autodecrypt_resolve_extension_dir)"
    src_defconfig=""

    for candidate in \
        "${extension_dir}/secure-boot-config/rk3588-config/${vendor_board}_defconfig" \
        "${extension_dir}/secure-boot-config/rk3576-config/${vendor_board}_defconfig"; do
        if [[ -f "${candidate}" ]]; then
            src_defconfig="${candidate}"
            break
        fi
    done

    [[ -n "${src_defconfig}" ]] || return 1

    cp -f "${src_defconfig}" "${target_defconfig}" || return 1
    display_alert "optee-autodecrypt" "Applied secure-boot-config defconfig fallback: $(basename "${src_defconfig}") -> ${target_defconfig}" "info"
}

function rk_autodecrypt_disable_fit_signature_in_defconfig() {
    local target_defconfig="$1"
    local disable_list="${RK_AUTODECRYPT_DISABLE_CONFIGS:-CONFIG_FIT_SIGNATURE}"
    local symbol

    [[ -f "${target_defconfig}" ]] || return 1

    for symbol in ${disable_list}; do
        if [[ -x scripts/config ]]; then
            rk_autodecrypt_run_host_command scripts/config --file "${target_defconfig}" --set-val "${symbol}" n || return 1
            continue
        fi

        # Fallback when scripts/config is unavailable in the current U-Boot tree.
        if grep -q "^${symbol}=" "${target_defconfig}"; then
            sed -i "s/^${symbol}=.*/${symbol}=n/" "${target_defconfig}" || return 1
        elif grep -q "^# ${symbol} is not set" "${target_defconfig}"; then
            :
        else
            printf "%s=n\n" "${symbol}" >> "${target_defconfig}" || return 1
        fi
    done

    display_alert "optee-autodecrypt" "Disabled configs in ${target_defconfig}: ${disable_list}" "info"
}

function rk_autodecrypt_prepare_defconfig_for_current_tree() {
    local vendor_board target_defconfig
    vendor_board="$(rk_autodecrypt_detect_vendor_board)"
    target_defconfig="configs/${vendor_board}_defconfig"

    rk_autodecrypt_copy_secure_boot_defconfig "${vendor_board}" ||
        exit_with_error "auto-decrypt defconfig copy failed" "vendor_board=${vendor_board} secure-boot-config"
    rk_autodecrypt_disable_fit_signature_in_defconfig "${target_defconfig}" ||
        exit_with_error "failed to disable CONFIG_FIT_SIGNATURE" "${target_defconfig}"
}

function rk_autodecrypt_install_patch_uboot_target_wrapper() {
    if [[ "$(type -t patch_uboot_target || true)" != "function" ]]; then
        display_alert "optee-autodecrypt" "patch_uboot_target not found, cannot install post-patch defconfig hook" "warn"
        return 0
    fi

    if [[ "$(type -t __rk_autodecrypt_patch_uboot_target_original || true)" == "function" ]]; then
        return 0
    fi

    eval "$(declare -f patch_uboot_target | sed '1s/^patch_uboot_target/__rk_autodecrypt_patch_uboot_target_original/')"
    patch_uboot_target() {
        __rk_autodecrypt_patch_uboot_target_original "$@" || return $?

        if rk_autodecrypt_nonsecure_mode_enabled && [[ "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; then
            rk_autodecrypt_prepare_defconfig_for_current_tree
        fi
    }

    display_alert "optee-autodecrypt" "Installed post-patch defconfig hook wrapper on patch_uboot_target" "info"
}

#
# OP-TEE Initramfs Helpers
#

function rk_autodecrypt_install_optee_client() {
    local root_dir="$1"
    local sdk_tools="$2"
    local optee_bin_dir="${sdk_tools}/external/security/bin/optee_v2/lib/arm64"

    display_alert "optee" "Installing OP-TEE client from library" "info"
    if [[ ! -d "${optee_bin_dir}" ]]; then
        display_alert "optee" "OP-TEE client binary directory not found: ${optee_bin_dir}" "err"
        return 1
    fi

    mkdir -p "${root_dir}/usr/bin" "${root_dir}/usr/lib" ||
        exit_with_error "Failed to create OP-TEE client directories" "${root_dir}"

    install -m 0755 "${optee_bin_dir}/tee-supplicant" "${root_dir}/usr/bin/tee-supplicant" ||
        exit_with_error "Failed to install tee-supplicant" "${optee_bin_dir}/tee-supplicant"

    local lib
    for lib in libteec.so libteec.so.1 libteec.so.1.0 libteec.so.1.0.0; do
        install -m 0644 "${optee_bin_dir}/${lib}" "${root_dir}/usr/lib/${lib}" ||
            exit_with_error "Failed to install ${lib}" "${optee_bin_dir}/${lib}"
    done
}

function rk_autodecrypt_build_and_install_tee_user() {
    local root_dir="$1"
    local sdk_tools="$2"
    local rk_tee_build_dir="${sdk_tools}/external/security/rk_tee_user/v2"
    local keybox_app_path ta_file_path

    display_alert "optee" "Starting compilation of rk_tee_user_v2" "info"
    if [[ ! -d "${rk_tee_build_dir}" ]]; then
        display_alert "optee" "rk_tee_user_v2 source directory not found: ${rk_tee_build_dir}" "err"
        return 1
    fi

    (
        cd "${rk_tee_build_dir}" || exit 1
        ./build.sh 6432
    ) || {
        display_alert "optee" "rk_tee_user_v2 compilation failed" "err"
        return 1
    }

    keybox_app_path="${rk_tee_build_dir}/out/extra_app/keybox_app"
    ta_file_path="${rk_tee_build_dir}/out/ta/extra_app/8c6cf810-685d-4654-ae71-8031beee467e.ta"
    [[ -f "${keybox_app_path}" ]] || exit_with_error "keybox_app not found after build" "${keybox_app_path}"
    [[ -f "${ta_file_path}" ]] || exit_with_error "TA file not found after build" "${ta_file_path}"

    mkdir -p "${root_dir}/lib/optee_armtz" ||
        exit_with_error "Failed to create optee_armtz" "${root_dir}/lib/optee_armtz"
    install -m 0755 "${keybox_app_path}" "${root_dir}/usr/bin/keybox_app" ||
        exit_with_error "Failed to install keybox_app" "${keybox_app_path}"
    install -m 0644 "${ta_file_path}" "${root_dir}/lib/optee_armtz/8c6cf810-685d-4654-ae71-8031beee467e.ta" ||
        exit_with_error "Failed to install OP-TEE TA" "${ta_file_path}"

    display_alert "optee" "rk_tee_user_v2 compiled and installed successfully" "info"
}

function rk_autodecrypt_install_initramfs_file() {
    local src="$1"
    local dst="$2"
    local label="$3"

    mkdir -p "$(dirname "${dst}")" ||
        exit_with_error "Failed to create initramfs directory" "$(dirname "${dst}")"

    [[ -f "${src}" ]] || exit_with_error "${label} source file not found" "${src}"
    cp "${src}" "${dst}" || {
        display_alert "optee" "Failed to copy ${label}" "err"
        return 1
    }
    chmod +x "${dst}"
    display_alert "optee" "${label} installation completed" "info"
}

function rk_autodecrypt_install_initramfs_hooks() {
    local root_dir="$1"
    local extension_dir
    extension_dir="$(rk_autodecrypt_resolve_extension_dir)"

    display_alert "optee" "Installing install-optee initramfs hook" "info"
    rk_autodecrypt_install_initramfs_file \
        "${extension_dir}/auto-decryption-config/install-optee" \
        "${root_dir}/etc/initramfs-tools/hooks/install-optee" \
        "install-optee hook" || return 1

    display_alert "optee" "Installing decryption-disk script" "info"
    rk_autodecrypt_install_initramfs_file \
        "${extension_dir}/auto-decryption-config/decryption-disk.sh" \
        "${root_dir}/etc/initramfs-tools/scripts/init-top/0-decryption-disk" \
        "decryption-disk script" || return 1
}

#
# Secure Storage Helpers
#

function rk_secure_storage_format_partition() {
    local sec_dev="$1"

    if [[ "${SECURE_STORAGE_SECURITY_FS_TYPE}" == "none" ]]; then
        return 0
    fi

    display_alert "secure-storage" "mkfs.${SECURE_STORAGE_SECURITY_FS_TYPE} on security (${sec_dev})" "info"
    if command -v mkfs.${SECURE_STORAGE_SECURITY_FS_TYPE} >/dev/null 2>&1; then
        mkfs.${SECURE_STORAGE_SECURITY_FS_TYPE} -q "${sec_dev}" ||
            display_alert "secure-storage" "security mkfs failed" "err"
    else
        display_alert "secure-storage" "mkfs.${SECURE_STORAGE_SECURITY_FS_TYPE} not found" "err"
    fi
}

function rk_secure_storage_write_passphrase() {
    local sec_dev="$1"
    local read_back

    if [[ "${CRYPTROOT_ENABLE}" != "yes" || -z "${CRYPTROOT_PASSPHRASE}" ]]; then
        return 0
    fi

    display_alert "secure-storage" "Writing CRYPTROOT_PASSPHRASE to security partition" "info"
    wait_for_disk_sync "before writing to security partition"

    printf "%s" "${CRYPTROOT_PASSPHRASE}" | dd of="${sec_dev}" bs=1 count="${#CRYPTROOT_PASSPHRASE}" conv=fsync 2>/dev/null || {
        display_alert "secure-storage" "Failed to write password to security partition" "err"
        return 1
    }

    sleep 1
    read_back="$(dd if="${sec_dev}" bs="${#CRYPTROOT_PASSPHRASE}" count=1 2>/dev/null)"
    if [[ "${read_back}" == "${CRYPTROOT_PASSPHRASE}" ]]; then
        display_alert "secure-storage" "Password written and verified successfully" "info"
    else
        display_alert "secure-storage" "Password write verification failed" "warn"
    fi

    sync
    blockdev --flushbufs "${sec_dev}" 2>/dev/null || true
}

#
# U-Boot Hooks
#

function build_custom_uboot__100_autodecrypt_prepare_defconfig() {
    if ! rk_autodecrypt_nonsecure_mode_enabled || [[ "${RK_OPTEE_BOOT_ENABLE}" != "yes" ]]; then
        return 0
    fi

    rk_autodecrypt_install_patch_uboot_target_wrapper
    rk_autodecrypt_prepare_defconfig_for_current_tree
}

#
# Initramfs Hooks
#

function pre_update_initramfs__300_optee_inject() {
    local root_dir="${MOUNT}"

    rk_autodecrypt_ensure_sdk_tools
    rk_autodecrypt_ensure_pycryptodome

    [[ -d "${root_dir}" ]] || {
        display_alert "optee" "root_dir does not exist: ${root_dir}" "err"
        return 0
    }

    rk_autodecrypt_install_optee_client "${root_dir}" "${RK_AUTODECRYPT_SDK_TOOLS}" || return 1
    rk_autodecrypt_build_and_install_tee_user "${root_dir}" "${RK_AUTODECRYPT_SDK_TOOLS}" || return 1
    display_alert "optee" "OP-TEE client installation completed" "info"
    rk_autodecrypt_install_initramfs_hooks "${root_dir}" || return 1
}

#
# Partition Hooks
#

function pre_prepare_partitions__secure_storage_partitions() {
    USE_HOOK_FOR_PARTITION="yes"
    SECURE_STORAGE_SECURITY_SIZE=${SECURE_STORAGE_SECURITY_SIZE:-4}
    SECURE_STORAGE_SECURITY_FS_TYPE=${SECURE_STORAGE_SECURITY_FS_TYPE:-none}
    display_alert "secure-storage" " security(${SECURE_STORAGE_SECURITY_SIZE}MiB) partitions" "info"
}

function create_partition_table__secure_storage() {
    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        if [[ -n "${SECURE_STORAGE_SECURITY_PART_INDEX}" ]]; then
            display_alert "secure-storage" "AB mode detected, reusing security partition index ${SECURE_STORAGE_SECURITY_PART_INDEX}" "info"
        else
            display_alert "secure-storage" "AB mode detected but security partition index is unset" "warn"
        fi
        return 0
    fi

    local next=${OFFSET}
    local p_index=1
    local script="label: ${IMAGE_PARTITION_TABLE:-gpt}\n"
    if [[ "${IMAGE_PARTITION_TABLE:-gpt}" == "gpt" ]]; then
        local gpt_table_length="${SECURE_STORAGE_GPT_TABLE_LENGTH:-64}"
        script+="table-length: ${gpt_table_length}\n"
    fi

    if [[ -n "${BIOSSIZE}" && ${BIOSSIZE} -gt 0 ]]; then
        [[ "${IMAGE_PARTITION_TABLE}" == "gpt" ]] || exit_with_error "BIOS partition only supports GPT" "BIOSSIZE=${BIOSSIZE}"
        script+="${p_index} : name=\"bios\", start=${next}MiB, size=${BIOSSIZE}MiB, type=21686148-6449-6E6F-744E-656564454649\n"
        next=$((next + BIOSSIZE)); p_index=$((p_index + 1))
    fi
    if [[ -n "${UEFISIZE}" && ${UEFISIZE} -gt 0 ]]; then
        local efi_type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
        script+="${p_index} : name=\"efi\", start=${next}MiB, size=${UEFISIZE}MiB, type=${efi_type}\n"
        next=$((next + UEFISIZE)); p_index=$((p_index + 1))
    fi
    if [[ -n "${BOOTSIZE}" && ${BOOTSIZE} -gt 0 && ( -n "${BOOTFS_TYPE}" || "${BOOTPART_REQUIRED}" == "yes" ) ]]; then
        local boot_type="BC13C2FF-59E6-4262-A352-B275FD6F7172"
        if [[ "${BOOT_RAW_MODE}" == "yes" ]]; then
            boot_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
        fi
        script+="${p_index} : name=\"boot\", start=${next}MiB, size=${BOOTSIZE}MiB, type=${boot_type}\n"
        next=$((next + BOOTSIZE)); p_index=$((p_index + 1))
    fi

    local sec_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    local security_part_index=${p_index}
    script+="${p_index} : name=\"security\", start=${next}MiB, size=${SECURE_STORAGE_SECURITY_SIZE}MiB, type=${sec_type}\n"
    next=$((next + SECURE_STORAGE_SECURITY_SIZE)); p_index=$((p_index + 1))

    local root_type
    if [[ "${IMAGE_PARTITION_TABLE}" == "gpt" ]]; then
        root_type="${PARTITION_TYPE_UUID_ROOT:-0FC63DAF-8483-4772-8E79-3D69D8477DE4}"
    else
        root_type="83"
    fi
    script+="${p_index} : name=\"rootfs\", start=${next}MiB, type=${root_type}\n"
    rootpart=${p_index}

    display_alert "secure-storage" "Custom partition table:\n${script}" "debug"
    echo -e "${script}" | run_host_command_logged sfdisk "${SDCARD}.raw" ||
        exit_with_error "secure-storage partition creation failed" "sfdisk"

    SECURE_STORAGE_SECURITY_PART_INDEX=${security_part_index}
}

function post_create_partitions__920_verify_secure_storage_layout() {
    if [[ -z "${SECURE_STORAGE_SECURITY_PART_INDEX}" ]]; then
        exit_with_error "secure-storage verification failed" "SECURE_STORAGE_SECURITY_PART_INDEX is empty"
    fi

    local ptable_dump
    ptable_dump="$(sfdisk -d "${SDCARD}.raw" 2>/dev/null || true)"
    if [[ -z "${ptable_dump}" ]]; then
        exit_with_error "secure-storage verification failed: cannot dump partition table" "${SDCARD}.raw"
    fi

    if ! grep -q 'name="security"' <<< "${ptable_dump}"; then
        display_alert "secure-storage" "Partition table dump:" "err"
        echo "${ptable_dump}" || true
        exit_with_error "secure-storage verification failed: no security partition name found" "${SDCARD}.raw"
    fi

    if ! grep -Eq "\\.raw${SECURE_STORAGE_SECURITY_PART_INDEX}([[:space:]]|:).*(name=\"security\")" <<< "${ptable_dump}"; then
        display_alert "secure-storage" "Partition table dump:" "err"
        echo "${ptable_dump}" || true
        exit_with_error "secure-storage verification failed: security index mismatch" "expected index=${SECURE_STORAGE_SECURITY_PART_INDEX}"
    fi

    display_alert "secure-storage" "Security partition table entry verified at index ${SECURE_STORAGE_SECURITY_PART_INDEX}" "info"
}

function format_partitions__secure_storage() {
    [[ -n "${SECURE_STORAGE_SECURITY_PART_INDEX}" ]] || return 0

    local sec_dev="${LOOP}p${SECURE_STORAGE_SECURITY_PART_INDEX}"
    check_loop_device "${sec_dev}"
    [[ -b "${sec_dev}" ]] ||
        exit_with_error "secure-storage verification failed: security partition device missing after loop setup" "${sec_dev}"

    rk_secure_storage_format_partition "${sec_dev}"
    rk_secure_storage_write_passphrase "${sec_dev}"
}
