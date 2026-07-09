#
# Shared Helpers
#

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rk-common.sh"

#
# Source Fetchers
#

function fetch_sources_tools__rksdk_tools() {
    rk_fetch_sdk_tools
}

#
# Platform And Path Resolution
#

function resolve_platform_rkbin_dir() {
    # Resolve platform-specific rkbin content directory.
    # Expected layout examples:
    # 1) rkbin/rk3576_rkbin/{RKTRUST,tools,...}
    # 2) rkbin/rk3588_rkbin/{RKTRUST,tools,...}
    # 3) legacy rkbin/{RKTRUST,tools,...}
    local rkbin_root platform rkbin_dir candidate
    rkbin_root="$(rk_sdk_rkbin_root)"
    platform="$(rk_detect_platform)"

    [[ "${platform}" != "unknown" ]] && rkbin_dir="${rkbin_root}/${platform}_rkbin"

    if [[ -n "${rkbin_dir}" && -d "${rkbin_dir}" ]]; then
        echo "${rkbin_dir}"
        return 0
    fi

    # If platform cannot be detected and both platform rkbin directories exist,
    # returning one arbitrarily is unsafe.
    if [[ "${platform}" == "unknown" && -d "${rkbin_root}/rk3576_rkbin" && -d "${rkbin_root}/rk3588_rkbin" ]]; then
        echo ""
        return 1
    fi

    if [[ -d "${rkbin_root}/RKTRUST" || -d "${rkbin_root}/tools" ]]; then
        echo "${rkbin_root}"
        return 0
    fi

    candidate="$(find "${rkbin_root}" -maxdepth 1 -mindepth 1 -type d -name "*_rkbin" | sort | head -n1)"
    if [[ -n "${candidate}" ]]; then
        echo "${candidate}"
        return 0
    fi

    echo "${rkbin_root}"
}

function resolve_platform_its_template() {
    # Match FIT load addresses to U-Boot's per-SoC ENV_MEM_LAYOUT_SETTINGS.
    local platform candidate boot_patch_dir

    platform="$(rk_detect_platform)"
    if [[ "${platform}" != "unknown" ]]; then
        for boot_patch_dir in \
            "${SRC}/patch/u-boot/${BOOTPATCHDIR:-}/fit-kernel" \
            "${SRC}/patch/u-boot/legacy/u-boot-radxa-rk35xx/fit-kernel"; do
            candidate="${boot_patch_dir}/${platform}_fit_kernel.its"
            [[ -f "${candidate}" ]] && { echo "${candidate}"; return 0; }
        done
    fi

    echo ""
}

function resolve_platform_bl32_blob() {
    local platform="$1"

    case "${platform}" in
        rk3576) echo "rk35/rk3576_bl32_v1.08.bin" ;;
        rk3588) echo "rk35/rk3588_bl32_v1.20.bin" ;;
        *) echo "" ;;
    esac
}

function rk_secure_boot_prepare_tee_bin() {
    local uboot_workdir="$1"
    local platform bl32_blob bl32_path

    platform="$(rk_detect_platform)"
    bl32_blob="$(resolve_platform_bl32_blob "${platform}")"
    if [[ -z "${bl32_blob}" ]]; then
        exit_with_error "No BL32 blob mapping found" "BOOT_SOC=${BOOT_SOC:-} BOARD=${BOARD:-}"
    fi

    bl32_path="${SRC}/cache/sources/rkbin-tools/${bl32_blob}"
    if [[ ! -f "${bl32_path}" ]]; then
        exit_with_error "BL32 blob missing" "${bl32_path}"
    fi

    install -m 0644 "${bl32_path}" "${uboot_workdir}/tee.bin" ||
        exit_with_error "Failed to stage BL32 as tee.bin" "${uboot_workdir}/tee.bin"
    display_alert "secure-uboot" "Staged BL32 for U-Boot FIT: ${bl32_blob} -> tee.bin" "info"
}

function rk_secure_boot_secure_bootconfig() {
    local board
    board="$(rk_detect_vendor_board)"

    if [[ "${board}" != "unknown" ]]; then
        echo "${board}-secure_defconfig"
        return 0
    fi

    echo ""
}

function rk_secure_boot_secure_defconfig_path() {
    local bootconfig="$1"
    local candidate boot_patch_dir

    for boot_patch_dir in \
        "${SRC}/patch/u-boot/${BOOTPATCHDIR:-}/defconfig" \
        "${SRC}/patch/u-boot/legacy/u-boot-radxa-rk35xx/defconfig"; do
        candidate="${boot_patch_dir}/${bootconfig}"
        [[ -f "${candidate}" ]] && { echo "${candidate}"; return 0; }
    done

    echo ""
}

function resolve_kernel_dtb_path() {
    # Resolve kernel DTB path for resource/FIT packaging.
    # Priority:
    # 1) RK_SECURE_KERNEL_DTB absolute path
    # 2) RK_SECURE_KERNEL_DTB filename under kernel rockchip dtb dir
    # 3) board + platform based candidate list (BOARD_NAME + BOOT_SOC)
    local kernel_src="$1"
    local dtb_dir platform board candidate override

    dtb_dir="${kernel_src}/arch/arm64/boot/dts/rockchip"
    override="${RK_SECURE_KERNEL_DTB:-}"

    if [[ -n "${override}" ]]; then
        if [[ -f "${override}" ]]; then
            echo "${override}"
            return 0
        fi
        if [[ -f "${dtb_dir}/${override}" ]]; then
            echo "${dtb_dir}/${override}"
            return 0
        fi
        display_alert "secure-uboot" "RK_SECURE_KERNEL_DTB not found: ${override}" "warn"
    fi

    platform="$(rk_detect_platform)"
    board="$(rk_detect_vendor_board)"

    if [[ "${platform}" != "unknown" && "${board}" != "unknown" ]]; then
        for candidate in \
            "${platform}-${board}.dtb" \
            "${platform}-recomputer-devkit.dtb"; do
            [[ -f "${dtb_dir}/${candidate}" ]] && { echo "${dtb_dir}/${candidate}"; return 0; }
        done
    fi

    echo ""
}

#
# U-Boot Build Helpers
#

function pre_config_uboot_target__rk_secure_boot_prepare() {
    # Goal: Generate keys required for FIT signing before U-Boot configuration, plus an optional system encryption key.
    if ! rk_optee_bootchain_enabled; then
        return 0
    fi

    if [[ "${RK_OPTEE_BOOT_ENABLE}" == "yes" && "${RK_SECURE_UBOOT_ENABLE}" != "yes" ]]; then
        enable_optee_bootchain_bl32_fit_node
    fi

    if [[ "${DISABLE_FIT_KEY_GEN}" == "yes" ]]; then
        return 0
    fi

    local uboot_workdir rkbin_root rkbin_dir rk_sign_tool keys_dir
    uboot_workdir="$(pwd)"  # Current directory is the U-Boot source tree
    keys_dir="${uboot_workdir}/keys"

    # Prefer UBOOT_DIR if user explicitly set it
    if [[ -n "${UBOOT_DIR}" ]]; then
        uboot_workdir="${UBOOT_DIR}"
        keys_dir="${UBOOT_DIR}/keys"
    fi

    rkbin_root="$(rk_sdk_rkbin_root)"
    rkbin_dir="$(resolve_platform_rkbin_dir)"
    echo "rkbin_root = ${rkbin_root}"
    echo "rkbin_dir  = ${rkbin_dir}"
    rk_secure_boot_prepare_tee_bin "${uboot_workdir}"

    # Find rk_sign_tool executable (prefer PATH)
    rk_sign_tool="$(command -v rk_sign_tool 2>/dev/null || true)"
    if [[ -z "${rk_sign_tool}" && -n "${rkbin_dir}" && -x "${rkbin_dir}/tools/rk_sign_tool" ]]; then
        rk_sign_tool="${rkbin_dir}/tools/rk_sign_tool"
    fi
    if [[ -z "${rk_sign_tool}" && -n "${rkbin_root}" && -x "${rkbin_root}/tools/rk_sign_tool" ]]; then
        rk_sign_tool="${rkbin_root}/tools/rk_sign_tool"
    fi

    if [[ -z "${rk_sign_tool}" ]]; then
        display_alert "secure-uboot" "rk_sign_tool not found, skipping FIT key generation" "warn"
        return 0
    fi

    mkdir -p "${keys_dir}" || { display_alert "secure-uboot" "Cannot create directory ${keys_dir}" "err"; return 1; }

    # Idempotent: if dev.key and dev.crt already exist, assume keys were generated and avoid overwriting
    if [[ -f "${keys_dir}/dev.key" && -f "${keys_dir}/dev.crt" ]]; then
        display_alert "secure-uboot" "Existing keys detected, skipping generation (${keys_dir})" "info"
        export UBOOT_FIT_KEYS_DIR="${keys_dir}"
        return 0
    fi

    display_alert "secure-uboot" "Generating initial key pair using rk_sign_tool" "info"
    (
        cd "${keys_dir}" || exit 1
        # Generate RSA 2048-bit key pair (tool outputs private_key.pem / public_key.pem)
        "${rk_sign_tool}" kk --bits 2048 --out ./ || exit_with_error "rk_sign_tool key generation failed" "${rk_sign_tool}"
        ln -rsf private_key.pem dev.key
        ln -rsf public_key.pem dev.pubkey

        # Generate self-signed certificate (subject can be adjusted as needed)
        openssl req -batch -new -x509 -key dev.key -out dev.crt -subj "/CN=Armbian FIT Key/" || exit_with_error "Failed to generate self-signed certificate" "dev.crt"

        # Generate random key for system encryption (32 bytes, hex encoded)
        openssl rand -hex 32 > system_enc_key || exit_with_error "Failed to generate system_enc_key" "system_enc_key"
    )

    # Export path for later stages/packaging
    export UBOOT_FIT_KEYS_DIR="${keys_dir}"
    display_alert "secure-uboot" "FIT keys generated: ${UBOOT_FIT_KEYS_DIR}" "info"
}

function extension_finish_config__rk_secure_bootconfig() {
    if ! rk_full_secure_boot_enabled; then
        return 0
    fi

    local secure_bootconfig secure_defconfig its_template
    secure_bootconfig="$(rk_secure_boot_secure_bootconfig)"
    if [[ -z "${secure_bootconfig}" ]]; then
        exit_with_error "No secure U-Boot defconfig mapping found" "BOOT_SOC=${BOOT_SOC} BOARD_NAME=${BOARD_NAME:-${BOARD:-}}"
    fi

    secure_defconfig="$(rk_secure_boot_secure_defconfig_path "${secure_bootconfig}")"
    if [[ -z "${secure_defconfig}" ]]; then
        exit_with_error "Secure U-Boot defconfig missing" "${SRC}/patch/u-boot/${BOOTPATCHDIR:-}/defconfig/${secure_bootconfig}"
    fi

    its_template="$(resolve_platform_its_template)"
    if [[ -z "${its_template}" ]]; then
        exit_with_error "Secure kernel FIT ITS template missing" "${SRC}/patch/u-boot/${BOOTPATCHDIR:-}/fit-kernel"
    fi

    display_alert "secure-uboot" "Using secure U-Boot defconfig: ${secure_bootconfig}" "info"
    declare -g BOOTCONFIG="${secure_bootconfig}"
}

function enable_optee_bootchain_bl32_fit_node() {
    # Non-secure OP-TEE bootchain still needs BL32 packed into vendor u-boot.itb.
    # Keep this as a narrow local change instead of reusing the full secure-boot overlay.
    local fit_generator="arch/arm/mach-rockchip/make_fit_atf.sh"

    if [[ ! -f "${fit_generator}" ]]; then
        display_alert "secure-uboot" "OP-TEE bootchain: FIT generator not found, skipping BL32 enable" "warn"
        return 0
    fi

    if grep -q '^[[:space:]]*gen_bl32_node[[:space:]]*$' "${fit_generator}"; then
        display_alert "secure-uboot" "OP-TEE bootchain: BL32 FIT node already enabled" "debug"
        return 0
    fi

    if grep -q '^[[:space:]]*#gen_bl32_node[[:space:]]*$' "${fit_generator}"; then
        sed -i 's/^[[:space:]]*#gen_bl32_node[[:space:]]*$/gen_bl32_node/' "${fit_generator}" ||
            exit_with_error "Failed to enable BL32 FIT node for OP-TEE bootchain" "${fit_generator}"
        display_alert "secure-uboot" "OP-TEE bootchain: enabled BL32 FIT node in ${fit_generator}" "info"
        return 0
    fi

    display_alert "secure-uboot" "OP-TEE bootchain: no commented gen_bl32_node marker found, leaving ${fit_generator} unchanged" "warn"
}

function rk_secure_boot_verify_fit_images() {
    local fit_image="$1"
    local fit_info

    [[ -f "${fit_image}" ]] || exit_with_error "FIT image missing after U-Boot build" "${fit_image}"

    if ! command -v dumpimage >/dev/null 2>&1; then
        display_alert "secure-uboot" "dumpimage not found, skip FIT image content verification" "warn"
        return 0
    fi

    fit_info="$(dumpimage -l "${fit_image}" 2>/dev/null || true)"
    [[ -n "${fit_info}" ]] || exit_with_error "Failed to parse FIT image" "${fit_image}"

    # For auto-decryption mode, BL32(OP-TEE) and the third ATF loadable are mandatory.
    if rk_autodecrypt_enabled; then
        grep -Eq 'Image [0-9]+ \(atf-3\)' <<< "${fit_info}" ||
            exit_with_error "FIT image validation failed: missing atf-3 loadable" "${fit_image}"
        grep -Eq 'Image [0-9]+ \(optee\)' <<< "${fit_info}" ||
            exit_with_error "FIT image validation failed: missing optee loadable" "${fit_image}"
    fi

    display_alert "secure-uboot" "FIT image validation passed (${fit_image})" "info"
}

function check_uboot_produced_binary_file__rk_secure_boot_fit() {
    if ! rk_optee_bootchain_enabled; then
        return 0
    fi

    [[ "${base_binfile}" == "u-boot.itb" ]] || return 0
    rk_secure_boot_verify_fit_images "${binfile}"
}

#
# FIT Image Helpers
#

function rk_secure_boot_kernel_bootargs() {
    local console_args root_args extra_args

    case "$(rk_detect_platform 2>/dev/null || echo unknown)" in
        rk3588)
            console_args="earlycon=uart8250,mmio32,0xfeb50000 console=ttyFIQ0 irqchip.gicv3_pseudo_nmi=0"
            ;;
        rk3576|*)
            console_args="earlycon=uart8250,mmio32,0x2ad40000 console=ttyFIQ0"
            ;;
    esac

    root_args="${RK_SECURE_BOOT_ROOTARGS:-root=/dev/mapper/armbian-root rw rootwait}"
    extra_args="${RK_SECURE_BOOT_EXTRA_BOOTARGS:-}"

    printf '%s %s' "${console_args}" "${root_args}"
    if [[ -n "${extra_args}" ]]; then
        printf ' %s' "${extra_args}"
    fi
}

function rk_secure_boot_patch_dtb_bootargs() {
    local dtb_file="$1"
    local bootargs="$2"

    [[ -f "${dtb_file}" ]] || exit_with_error "FIT packaging failed: DTB copy missing" "${dtb_file}"
    if ! command -v fdtput >/dev/null 2>&1; then
        exit_with_error "FIT packaging failed: fdtput missing, cannot inject root bootargs" "device-tree-compiler"
    fi

    fdtput -c "${dtb_file}" /chosen 2>/dev/null || true
    fdtput -t s "${dtb_file}" /chosen bootargs "${bootargs}" ||
        exit_with_error "FIT packaging failed: cannot inject /chosen/bootargs" "${dtb_file}"
    display_alert "fit-post-initrd" "Injected DTB bootargs: ${bootargs}" "info"
}

function rk_secure_boot_find_ramdisk() {
    local boot_dir="$1"

    RK_SECURE_BOOT_RAMDISK_PATH=""
    if compgen -G "${boot_dir}/initrd.img-"* > /dev/null; then
        RK_SECURE_BOOT_RAMDISK_PATH="$(ls -1t ${boot_dir}/initrd.img-* | head -1)"
        display_alert "fit-post-initrd" "Using official initrd: ${RK_SECURE_BOOT_RAMDISK_PATH}" "info"
    elif [[ -f "${boot_dir}/uInitrd" ]]; then
        RK_SECURE_BOOT_RAMDISK_PATH="${boot_dir}/uInitrd"
        display_alert "fit-post-initrd" "Using uInitrd: ${RK_SECURE_BOOT_RAMDISK_PATH}" "info"
    elif [[ -f "${SRC}/userpatches/overlay/rootfs.cpio.gz" ]]; then
        RK_SECURE_BOOT_RAMDISK_PATH="${SRC}/userpatches/overlay/rootfs.cpio.gz"
        display_alert "fit-post-initrd" "Official initrd not found, falling back to rootfs.cpio.gz" "warn"
    else
        exit_with_error "FIT packaging failed: no initramfs found" "${boot_dir}"
    fi
}

function rk_secure_boot_find_kernel_image() {
    local boot_dir="$1"
    local ramdisk_path="$2"
    local kernel_version=""
    local kernel_path=""

    case "$(basename "${ramdisk_path}")" in
        initrd.img-*) kernel_version="$(basename "${ramdisk_path}" | sed 's/^initrd\.img-//')" ;;
    esac

    if [[ -n "${kernel_version}" && -f "${boot_dir}/vmlinuz-${kernel_version}" ]]; then
        kernel_path="${boot_dir}/vmlinuz-${kernel_version}"
    elif compgen -G "${boot_dir}/vmlinuz-"* > /dev/null; then
        kernel_path="$(ls -1t ${boot_dir}/vmlinuz-* | head -1)"
    fi

    [[ -n "${kernel_path}" && -f "${kernel_path}" ]] ||
        exit_with_error "FIT packaging failed: installed kernel image missing" "${boot_dir}/vmlinuz-*"

    RK_SECURE_BOOT_KERNEL_IMAGE_PATH="${kernel_path}"
    display_alert "fit-post-initrd" "Using installed kernel image: ${RK_SECURE_BOOT_KERNEL_IMAGE_PATH}" "info"
}

function rk_secure_boot_resolve_mkimage() {
    local rkbin_dir

    RK_SECURE_BOOT_MKIMAGE=""
    rkbin_dir="$(resolve_platform_rkbin_dir)"
    if [[ -x "${rkbin_dir}/tools/mkimage" ]]; then
        RK_SECURE_BOOT_MKIMAGE="${rkbin_dir}/tools/mkimage"
    elif [[ -x "$(rk_sdk_rkbin_root)/tools/mkimage" ]]; then
        RK_SECURE_BOOT_MKIMAGE="$(rk_sdk_rkbin_root)/tools/mkimage"
    fi

    [[ -x "${RK_SECURE_BOOT_MKIMAGE}" ]] ||
        exit_with_error "FIT packaging failed: mkimage missing" "${RK_SECURE_BOOT_MKIMAGE}"
}

function rk_secure_boot_prepare_fit_workdir() {
    local fit_work="$1"
    local kernel_img_path="$2"
    local dtb_path="$3"
    local resource_path="$4"
    local ramdisk_path="$5"

    rm -rf "${fit_work}" 2>/dev/null || true
    mkdir -p "${fit_work}" || exit_with_error "FIT packaging failed: cannot create temporary directory" "${fit_work}"

    cp -f "${kernel_img_path}" "${fit_work}/Image"
    cp -f "${dtb_path}" "${fit_work}/board.dtb"
    if [[ -f "${resource_path}" ]]; then
        cp -f "${resource_path}" "${fit_work}/resource.img"
    else
        : > "${fit_work}/resource.img"
    fi
    cp -f "${ramdisk_path}" "${fit_work}/initrd.img"
    rk_secure_boot_patch_dtb_bootargs "${fit_work}/board.dtb" "$(rk_secure_boot_kernel_bootargs)"
}

function rk_secure_boot_apply_fit_template() {
    local fit_work="$1"
    local its_template

    its_template="$(resolve_platform_its_template)"
    if [[ ! -f "${its_template}" ]]; then
        exit_with_error "FIT packaging failed: ITS template missing" "${SRC}/patch/u-boot/${BOOTPATCHDIR:-}/fit-kernel"
    fi
    display_alert "fit-post-initrd" "Using ITS template: ${its_template}" "info"

    cp -f "${its_template}" "${fit_work}/boot-final.its"
    sed -i "s|@KERNEL_DTB@|${fit_work}/board.dtb|g" "${fit_work}/boot-final.its"
    sed -i "s|@KERNEL_IMG@|${fit_work}/Image|g" "${fit_work}/boot-final.its"
    sed -i "s|@RAMDISK_IMG@|${fit_work}/initrd.img|g" "${fit_work}/boot-final.its"
    sed -i "s|@RESOURCE_IMG@|${fit_work}/resource.img|g" "${fit_work}/boot-final.its"
}

function rk_secure_boot_generate_initial_fit() {
    local fit_work="$1"
    local rk_mkimage="$2"

    display_alert "fit-post-initrd" "Generating final FIT (initial boot-final.img)" "info"
    (
        cd "${fit_work}" || exit 1
        "${rk_mkimage}" -f boot-final.its  -E -p 0x800 boot-final.img || exit 1
    ) || { rm -rf "${fit_work}"; exit_with_error "FIT packaging failed: mkimage generation failed" "${fit_work}/boot-final.its"; }
}

function rk_secure_boot_resolve_uboot_dir() {
    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"

    RK_SECURE_BOOT_UBOOT_DIR="${uboot_src}"
    if [[ -z "${RK_SECURE_BOOT_UBOOT_DIR}" || ! -d "${RK_SECURE_BOOT_UBOOT_DIR}" ]]; then
        RK_SECURE_BOOT_UBOOT_DIR="$(find "${SRC}/cache/sources/u-boot-worktree" -maxdepth 4 -type d -name "u-boot-*${LINUXFAMILY}*" | head -1)"
    fi
}

function rk_secure_boot_run_secondary_fit_signing() {
    local fit_work="$1"
    local uboot_dir="$2"

    if [[ -x "${uboot_dir}/scripts/fit.sh" ]]; then
        display_alert "fit-post-initrd" "Executing secondary signing script fit.sh" "info"
        (
            cd "${uboot_dir}" || exit 1
            cp "${fit_work}/boot-final.img" .
            ./scripts/fit.sh --boot_img "${fit_work}/boot-final.img" || exit 1
        ) || display_alert "fit-post-initrd" "fit.sh execution failed, trying fallback image path" "warn"
    else
        display_alert "fit-post-initrd" "fit.sh not found, using boot-final.img as fallback" "warn"
    fi
}

function rk_secure_boot_stage_final_fit() {
    local fit_work="$1"
    local uboot_dir="$2"
    local fit_output_candidate=""
    local canonical_fit_image="${SRC}/cache/sources/${BOOTSOURCEDIR}/fit/boot.itb"

    if [[ -f "${uboot_dir}/fit/boot.itb" ]]; then
        fit_output_candidate="${uboot_dir}/fit/boot.itb"
    elif [[ -f "${uboot_dir}/boot-final.img" ]]; then
        fit_output_candidate="${uboot_dir}/boot-final.img"
    elif [[ -f "${fit_work}/boot-final.img" ]]; then
        fit_output_candidate="${fit_work}/boot-final.img"
    else
        rm -rf "${fit_work}" 2>/dev/null || true
        exit_with_error "FIT packaging failed: no final FIT image generated" "${uboot_dir}/fit/boot.itb"
    fi

    mkdir -p "$(dirname "${canonical_fit_image}")" ||
        exit_with_error "FIT packaging failed: cannot create fit output directory" "$(dirname "${canonical_fit_image}")"
    if [[ "${fit_output_candidate}" == "${canonical_fit_image}" ]] || \
       [[ -e "${canonical_fit_image}" && "${fit_output_candidate}" -ef "${canonical_fit_image}" ]]; then
        display_alert "fit-post-initrd" "Final FIT image already in canonical location: ${canonical_fit_image}" "info"
    else
        cp -f "${fit_output_candidate}" "${canonical_fit_image}" ||
            exit_with_error "FIT packaging failed: cannot stage final fit image" "${canonical_fit_image}"
    fi

    export RK_SECURE_BOOT_FIT_IMAGE="${canonical_fit_image}"
    display_alert "fit-post-initrd" "Final FIT image ready: ${RK_SECURE_BOOT_FIT_IMAGE}" "info"
}

function rk_secure_boot_remove_boot_fstab_entries() {
    local fstab_file="${MOUNT}/etc/fstab"

    display_alert "fit-flash" "Removing boot settings from fstab" "info"

    if [[ ! -f "${fstab_file}" ]]; then
        display_alert "fit-flash" "No fstab file" "info"
        return 0
    fi

    if ! grep -q "/boot" "${fstab_file}" 2>/dev/null; then
        display_alert "fit-flash" "No boot entries" "info"
        return 0
    fi

    display_alert "secure-uboot" "Removing boot partition mount entries from fstab" "info"
    display_alert "secure-uboot" "fstab content before sed execution:" "info"
    cat "${fstab_file}" 2>/dev/null || true

    cp "${fstab_file}" "${fstab_file}.bak" 2>/dev/null || true
    sed -i '\|/boot|d' "${fstab_file}" 2>/dev/null || true

    display_alert "secure-uboot" "fstab content after sed execution:" "info"
    cat "${fstab_file}" 2>/dev/null || true

    if ! grep -q "/boot" "${fstab_file}" 2>/dev/null; then
        rm -f "${fstab_file}.bak" 2>/dev/null || true
        display_alert "secure-uboot" "Successfully removed boot partition mount entries from fstab" "info"
    else
        display_alert "secure-uboot" "Warning: /boot entries still exist in fstab, please check manually" "warn"
    fi
}

function rk_secure_boot_disable_kernel_root_symlinks() {
    local root_dir="$1"
    local conf_file="${root_dir}/etc/kernel-img.conf"

    display_alert "secure-uboot" "Disabling Debian kernel root symlinks for RAW FIT boot" "info"

    [[ -n "${root_dir}" ]] || {
        display_alert "secure-uboot" "Cannot disable kernel symlinks: root dir is empty" "warn"
        return 0
    }

    mkdir -p "${root_dir}/etc" || {
        display_alert "secure-uboot" "Cannot create ${root_dir}/etc" "warn"
        return 0
    }

    touch "${conf_file}" || {
        display_alert "secure-uboot" "Cannot create ${conf_file}" "warn"
        return 0
    }
    sed -i -E '/^[[:space:]]*do_symlinks[[:space:]]*=/d' "${conf_file}" || true
    cat >> "${conf_file}" <<'EOF'

# RAW FIT images boot from a non-filesystem boot partition.
do_symlinks = No
EOF
}

function pre_install_kernel_debs__300_disable_kernel_root_symlinks_for_raw_fit() {
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    rk_secure_boot_disable_kernel_root_symlinks "${SDCARD}"
}

#
# Partition Hooks
#

function pre_prepare_partitions__040_require_secure_storage_hook() {
    # If secure boot + auto decrypt are enabled together, secure storage hook must be present.
    if [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]; then
        if [[ "$(type -t create_partition_table__secure_storage || true)" != "function" ]]; then
            exit_with_error "rk-auto-decryption secure storage partition hook is missing" "create_partition_table__secure_storage not found"
        fi
    fi
}

function pre_prepare_partitions__set_raw_boot_partition() {
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    display_alert "secure-uboot" "Enabling RAW boot partition mode" "info"

    BOOTPART_REQUIRED="yes"

    # Ensure boot partition has enough space (set to 256 MiB)
    export BOOTSIZE=256
    display_alert "secure-uboot" "Forcing boot partition size: ${BOOTSIZE} MiB" "info"

    # Disable standard boot filesystem handling
    export BOOT_RAW_MODE="yes"
}

function modify_boot_partition_name() {
    export BOOT_FS_LABEL="boot"
    display_alert "secure-uboot" "Set boot partition label to: ${BOOT_FS_LABEL}" "info"
}

function pre_prepare_partitions__change_boot_partition_name() {
    if ! rk_full_secure_boot_enabled; then
        return 0
    fi

    modify_boot_partition_name
    mkopts_label[ext4]=" -U 0b06166d-3930-4176-b30a-900806bd6202 -L  "
}

function post_create_partitions__handle_raw_boot() {
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    display_alert "secure-uboot" "RAW boot mode: Save bootpart index and prevent filesystem creation" "debug"

    # Ensure BOOTSIZE is set
    if [[ -z "${BOOTSIZE}" ]]; then
        export BOOTSIZE=256
        display_alert "secure-uboot" "Setting default BOOTSIZE=${BOOTSIZE} MiB" "info"
    fi

    # Save original bootpart index for later dd write
    export RAW_BOOT_PART_INDEX="${bootpart}"
    display_alert "secure-uboot" "Saved boot partition index: ${RAW_BOOT_PART_INDEX}" "debug"

    # Delay clearing bootpart variable, clear it in mount_chroot_script stage
    # This ensures correct use of BOOTSIZE during partition creation
}

function pre_mount_chroot_script__delayed_raw_boot_cleanup() {
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    # Delay clearing bootpart to prevent subsequent filesystem creation and mount
    if [[ "${BOOT_RAW_MODE}" == "yes" ]]; then
        display_alert "secure-uboot" "Delayed cleanup: Clearing bootpart variable" "debug"
        bootpart=""
    fi
}

function pre_package_kernel_image__create_resource_img() {
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    local kernel_src="${SRC}/cache/sources/${LINUXSOURCEDIR}"
    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
    local dtb_path
    dtb_path="$(resolve_kernel_dtb_path "${kernel_src}")"
    display_alert "Creating resource.img" "Using DTB: ${dtb_path:-<not found>}" "info"
    local resource_tool="${uboot_src}/tools/resource_tool"
    local output_resource_img="${kernel_src}/resource.img"

    # Check necessary files and tools
    [[ -f "${dtb_path}" ]] ||
        exit_with_error "Missing DTB file for resource.img" "${dtb_path}"

    [[ -n "${resource_tool}" && -x "${resource_tool}" ]] ||
        exit_with_error "Missing resource_tool" "${resource_tool}"

    display_alert "Using resource_tool" "${resource_tool}" "debug"
    
    # Create temporary work directory
    local temp_work_dir
    temp_work_dir="$(mktemp -d)" ||
        exit_with_error "Failed to create temporary resource.img work directory" "${TMPDIR:-/tmp}"
    
    # Copy DTB file to work directory and inject bootargs before packing resource.img.
    # Rockchip vendor boot flows may pass the DTB from resource.img rather than the
    # FIT fdt image, so both copies must carry a valid root= argument.
    local dtb_filename=$(basename "${dtb_path}")
    cp "${dtb_path}" "${temp_work_dir}/${dtb_filename}"
    rk_secure_boot_patch_dtb_bootargs "${temp_work_dir}/${dtb_filename}" "$(rk_secure_boot_kernel_bootargs)"

    # Ensure output directory exists and is writable
    local output_dir=$(dirname "${output_resource_img}")
    mkdir -p "${output_dir}"

    # Use resource_tool to create resource.img
    (
        cd "${temp_work_dir}"

        display_alert "resource.img" "Packing DTB ${dtb_filename} -> ${output_resource_img}" "debug"

        # Create in current directory first, then move to target location
        "${resource_tool}" --pack "${dtb_filename}" "./resource.img" || {
            display_alert "Failed to create resource.img in temp dir" "resource_tool pack failed" "err"
            rm -rf "${temp_work_dir}"
            return 1
        }

        # Move to final location
        if [[ -f "./resource.img" ]]; then
            mv "./resource.img" "${output_resource_img}" || {
                display_alert "Failed to move resource.img to ${output_resource_img}" "mv failed" "err"
                rm -rf "${temp_work_dir}"
                return 1
            }
        else
            display_alert "resource.img not created in temp directory" "file missing" "err"
            rm -rf "${temp_work_dir}"
            return 1
        fi
    )
    
    # Clean up temporary directory
    rm -rf "${temp_work_dir}"
    
    # Verify generated resource.img
    if [[ -f "${output_resource_img}" && -s "${output_resource_img}" ]]; then
        local img_size=$(stat -c %s "${output_resource_img}")
        display_alert "Successfully created resource.img" "Size: ${img_size} bytes" "info"
        
        # Optional: Display resource.img content
        "${resource_tool}" --print --image="${output_resource_img}" 2>/dev/null || true
    else
        display_alert "Failed to create resource.img" "File not found or empty" "err"
        return 1
    fi
}

function pre_umount_final_image__package_fit() {
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    local boot_dir="${MOUNT}/boot"  # Use real /boot from mount point
    local kernel_src="${SRC}/cache/sources/${LINUXSOURCEDIR}"
    local kernel_img_path
    local resource_path="${kernel_src}/resource.img"
    local fit_work="${TMPDIR:-/tmp}/fit-final-$$"
    local dtb_path

    display_alert "fit-post-initrd" "Starting to rebuild FIT before final unmount" "info"
    [[ -d "${boot_dir}" ]] || exit_with_error "FIT packaging failed: /boot does not exist" "${boot_dir}"

    rk_secure_boot_find_ramdisk "${boot_dir}"
    rk_secure_boot_find_kernel_image "${boot_dir}" "${RK_SECURE_BOOT_RAMDISK_PATH}"
    kernel_img_path="${RK_SECURE_BOOT_KERNEL_IMAGE_PATH}"

    dtb_path="$(resolve_kernel_dtb_path "${kernel_src}")"
    display_alert "fit-post-initrd" "Embedding DTB into FIT: ${dtb_path} (name=$(basename "${dtb_path}" 2>/dev/null || echo unknown))" "info"
    [[ -f "${kernel_img_path}" ]] || exit_with_error "FIT packaging failed: kernel image missing" "${kernel_img_path}"
    [[ -f "${dtb_path}" ]] || exit_with_error "FIT packaging failed: DTB missing" "${dtb_path}"

    rk_secure_boot_resolve_mkimage
    rk_secure_boot_prepare_fit_workdir "${fit_work}" "${kernel_img_path}" "${dtb_path}" "${resource_path}" "${RK_SECURE_BOOT_RAMDISK_PATH}"
    rk_secure_boot_apply_fit_template "${fit_work}"
    rk_secure_boot_generate_initial_fit "${fit_work}" "${RK_SECURE_BOOT_MKIMAGE}"
    rk_secure_boot_resolve_uboot_dir
    rk_secure_boot_run_secondary_fit_signing "${fit_work}" "${RK_SECURE_BOOT_UBOOT_DIR}"
    rk_secure_boot_stage_final_fit "${fit_work}" "${RK_SECURE_BOOT_UBOOT_DIR}"

    rm -rf "${fit_work}" 2>/dev/null || true
    rk_secure_boot_remove_boot_fstab_entries
}

function post_umount_final_image__flash_fit_kernel() {
    # After final unmount, write FIT image to boot partition (only in RAW boot mode)
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    display_alert "fit-flash" "RAW boot mode: Writing FIT image to boot partition" "info"

    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
    local fit_image="${RK_SECURE_BOOT_FIT_IMAGE:-${uboot_src}/fit/boot.itb}"
    local boot_part_index="${RAW_BOOT_PART_INDEX:-1}"
    local boot_dev="${LOOP}p${boot_part_index}"

    display_alert "fit-flash" "Target boot device: ${boot_dev}" "info"

    if [[ ! -f "${fit_image}" ]]; then
        exit_with_error "FIT flash failed: FIT image does not exist" "${fit_image}"
    fi

    [[ -b "${boot_dev}" ]] || exit_with_error "FIT flash failed: target boot partition does not exist" "${boot_dev}"

    display_alert "fit-flash" "dd if=${fit_image} of=${boot_dev}" "info"
    dd if="${fit_image}" of="${boot_dev}" conv=fsync || exit_with_error "FIT flash failed: dd write error" "${boot_dev}"

    sync
    display_alert "fit-flash" "FIT image write completed" "info"
}
