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
# Mode Predicates
#

function rk_full_secure_boot_enabled() {
    [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" ]]
}

function rk_optee_bootchain_enabled() {
    rk_full_secure_boot_enabled || [[ "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]
}

function rk_autodecrypt_enabled() {
    [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]
}

function rk_autodecrypt_fit_boot_required() {
    rk_full_secure_boot_enabled ||
        { rk_autodecrypt_enabled && [[ "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; }
}

#
# Platform And Path Resolution
#

function resolve_rockchip_sdk_rkbin_root() {
    rk_sdk_rkbin_root
}

function rk_secure_boot_platform_from_name() {
    rk_platform_from_name "$@"
}

function rk_secure_boot_default_board() {
    rk_default_vendor_board "$1"
}

function detect_rk_secure_boot_platform() {
    # Return value: rk3576 / rk3588 / unknown
    # Platform detection prefers BOOT_SOC, then falls back to board names.
    rk_detect_platform
}

function detect_rk_secure_boot_board() {
    # Return value: canonical vendor board name, e.g. recomputer-rk3576-devkit / recomputer-rk3588-devkit / unknown
    # Board detection is based on BOARD_NAME first, fallback to BOARD.
    rk_detect_vendor_board
}

function resolve_platform_rkbin_dir() {
    # Resolve platform-specific rkbin content directory.
    # Expected layout examples:
    # 1) rkbin/rk3576_rkbin/{RKTRUST,tools,...}
    # 2) rkbin/rk3588_rkbin/{RKTRUST,tools,...}
    # 3) legacy rkbin/{RKTRUST,tools,...}
    local rkbin_root platform rkbin_dir candidate
    rkbin_root="$(resolve_rockchip_sdk_rkbin_root)"
    platform="$(detect_rk_secure_boot_platform)"

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

function resolve_rk_secure_extension_dir() {
    # Resolve extension root robustly across different Armbian extension layouts.
    rk_resolve_extension_dir "secure-boot-config"
}

function resolve_platform_defconfig_path() {
    # Resolve platform + board specific defconfig from the current secure-boot-config layout.
    local secure_config_dir="$1"
    local platform board candidate

    platform="$(detect_rk_secure_boot_platform)"
    board="$(detect_rk_secure_boot_board)"

    if [[ "${platform}" != "unknown" && "${board}" != "unknown" ]]; then
        candidate="${secure_config_dir}/${platform}-config/${board}_defconfig"
        [[ -f "${candidate}" ]] && { echo "${candidate}"; return 0; }
    fi

    echo ""
}

function resolve_platform_its_template() {
    # Match FIT load addresses to U-Boot's per-SoC ENV_MEM_LAYOUT_SETTINGS.
    local secure_config_dir="$1"
    local platform candidate

    platform="$(detect_rk_secure_boot_platform)"
    if [[ "${platform}" != "unknown" ]]; then
        candidate="${secure_config_dir}/${platform}_fit_kernel.its"
        [[ -f "${candidate}" ]] && { echo "${candidate}"; return 0; }
    fi

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

    platform="$(detect_rk_secure_boot_platform)"
    board="$(detect_rk_secure_boot_board)"

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

function pre_config_uboot_target__generate_fit_keys() {
    # Goal: Generate keys required for FIT signing before U-Boot configuration, plus an optional system encryption key.
    if ! rk_optee_bootchain_enabled; then
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

    rkbin_root="$(resolve_rockchip_sdk_rkbin_root)"
    rkbin_dir="$(resolve_platform_rkbin_dir)"
    echo "rkbin_root = ${rkbin_root}"
    echo "rkbin_dir  = ${rkbin_dir}"

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


function setup_vendor_build_environment() {
    if [[ "${DISABLE_FIT_KEY_GEN}" != "yes" ]]; then
        pre_config_uboot_target__generate_fit_keys || display_alert "secure-uboot" "FIT key generation failed" "warn"
    fi
}

function apply_secure_boot_config() {
    local extension_dir secure_config_dir
    extension_dir="$(resolve_rk_secure_extension_dir)"
    secure_config_dir="${extension_dir}/secure-boot-config"

    if [[ ! -d "${secure_config_dir}" ]]; then
        display_alert "secure-uboot" "secure-boot-config directory does not exist: ${secure_config_dir}" "debug"
        return 0
    fi

    display_alert "secure-uboot" "Applying secure-boot-config files and patches" "info"

    # 1. defconfig files (platform-specific)
    display_alert "secure-uboot" "Applying defconfig files" "info"
    mkdir -p configs
    local defconfig_count=0
    local selected_defconfig platform board
    platform="$(detect_rk_secure_boot_platform)"
    board="$(detect_rk_secure_boot_board)"
    selected_defconfig="$(resolve_platform_defconfig_path "${secure_config_dir}")"

    if [[ -n "${selected_defconfig}" ]]; then
        cp -f "${selected_defconfig}" configs/ && defconfig_count=$((defconfig_count + 1))
        display_alert "secure-uboot" "Applied defconfig: $(basename "${selected_defconfig}") (BOOT_SOC=${BOOT_SOC} BOARD_NAME=${BOARD_NAME:-${BOARD:-}})" "info"
    else
        exit_with_error "No matching defconfig found for platform/board" "BOOT_SOC=${BOOT_SOC} BOARD_NAME=${BOARD_NAME:-${BOARD:-}} platform=${platform} board=${board}"
    fi

    if [[ "${defconfig_count}" -lt 1 ]]; then
        exit_with_error "No defconfig files found under secure-boot-config" "${secure_config_dir}"
    fi
    display_alert "secure-uboot" "Applied ${defconfig_count} defconfig file(s)" "debug"

    # 2. Device tree files
    if [[ -d "${secure_config_dir}/dt" ]]; then
        display_alert "secure-uboot" "Applying device tree files" "info"
        mkdir -p arch/arm/dts
        local dt_count=0
        for dt_file in "${secure_config_dir}/dt"/*; do
            [[ -e "${dt_file}" ]] || continue
            cp -rf "${dt_file}" arch/arm/dts/ && dt_count=$((dt_count + 1))
        done
        display_alert "secure-uboot" "Applied ${dt_count} device tree files" "debug"
    fi

    # 3. board directory
    if [[ -d "${secure_config_dir}/board" ]]; then
        display_alert "secure-uboot" "Applying board-level configuration files" "info"
        local board_count=0
        # Recursively copy the whole board directory structure
        cp -rf "${secure_config_dir}/board"/* . 2>/dev/null && board_count=$((board_count + 1))
        display_alert "secure-uboot" "Applied board-level configuration files" "debug"
    fi

    # 4. Patch files (if any)
    if compgen -G "${secure_config_dir}"/*.patch > /dev/null; then
        display_alert "secure-uboot" "Applying secure boot patches" "info"
        local patch_applied=0
        local patch_failed=0
        for patch_file in "${secure_config_dir}"/*.patch; do
            [[ -f "${patch_file}" ]] || continue
            local patch_name
            patch_name=$(basename "${patch_file}")

            # Check if patch can be applied
            if git apply --check "${patch_file}" 2>/dev/null; then
                if git apply "${patch_file}"; then
                    patch_applied=$((patch_applied + 1))
                    display_alert "secure-uboot" "Patch applied: ${patch_name}" "debug"
                else
                    patch_failed=$((patch_failed + 1))
                    display_alert "secure-uboot" "Failed to apply patch: ${patch_name}" "err"
                fi
            else
                # Fallback to patch(1)
                if patch -p1 < "${patch_file}" 2>/dev/null; then
                    patch_applied=$((patch_applied + 1))
                else
                    patch_failed=$((patch_failed + 1))
                    display_alert "secure-uboot" "Patch application failed (patch): ${patch_name}" "err"
                fi
            fi
        done

        display_alert "secure-uboot" "Patch application completed: Success=${patch_applied} Failed=${patch_failed}" "info"
    fi

    # 5. Handle other configuration files
    local config_files=(
        "include/configs"
        "scripts"
        "include"
    )

    for config_subdir in "${config_files[@]}"; do
        if [[ -d "${secure_config_dir}/${config_subdir}" ]]; then
            display_alert "secure-uboot" "Applying configuration directory: ${config_subdir}" "info"
            mkdir -p "${config_subdir}"
            cp -rf "${secure_config_dir}/${config_subdir}"/* "${config_subdir}/" 2>/dev/null || true
        fi
    done

    display_alert "secure-uboot" "secure-boot-config application completed" "info"
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

    [[ -f "${fit_image}" ]] || exit_with_error "FIT image missing after vendor build" "${fit_image}"

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

function generate_uboot_metadata() {
    local dst_dir="${1}"
    local vendor_board="${2}"

    cat > "${dst_dir}/u-boot-metadata-target-1.sh" <<VENDOR_META
declare -a UBOOT_TARGET_BINS=($(ls "${dst_dir}" 2>/dev/null | sed 's/^/"/;s/$/"/' | tr '\n' ' '))
declare UBOOT_TARGET_MAKE='${vendor_board}'
declare UBOOT_TARGET_CONFIG='vendor-final.config'
VENDOR_META
}

function collect_vendor_artifacts() {
    local vendor_board="${1}"
    local dst_dir="${uboottempdir}/usr/lib/${uboot_name}"

    mkdir -p "${dst_dir}" || exit_with_error "Failed to create packaging directory" "${dst_dir}"

    # Possible artifacts list
    local artifacts=(
        "rkspi_loader.img"
        "idbloader.img"
        "u-boot.bin"
        "u-boot-nodtb.bin"
        "u-boot.dtb"
        "u-boot.itb"
        "u-boot.its"
        "spl/u-boot-spl.bin"
        "tpl/u-boot-tpl.bin"
    )

    local copied=0
    for artifact in "${artifacts[@]}"; do
        if [[ -f "${artifact}" ]]; then
            cp -v "${artifact}" "${dst_dir}/" 2>&1 | grep -v -- '->' || true
            copied=$((copied+1))
        fi
    done

    if [[ ${copied} -gt 0 ]]; then
        display_alert "secure-uboot" "Copied ${copied} artifacts to ${dst_dir}" "info"
    fi

    # Save final config
    if [[ -f .config ]]; then
        cp .config "${dst_dir}/vendor-final.config"
    fi

    # Generate metadata
    generate_uboot_metadata "${dst_dir}" "${vendor_board}"
}

#
# FIT Image Helpers
#

function rk_secure_boot_kernel_bootargs() {
    local console_args root_args extra_args

    case "$(detect_rk_secure_boot_platform 2>/dev/null || echo unknown)" in
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

function rk_secure_boot_resolve_mkimage() {
    local rkbin_dir

    RK_SECURE_BOOT_MKIMAGE=""
    rkbin_dir="$(resolve_platform_rkbin_dir)"
    if [[ -x "${rkbin_dir}/tools/mkimage" ]]; then
        RK_SECURE_BOOT_MKIMAGE="${rkbin_dir}/tools/mkimage"
    elif [[ -x "$(resolve_rockchip_sdk_rkbin_root)/tools/mkimage" ]]; then
        RK_SECURE_BOOT_MKIMAGE="$(resolve_rockchip_sdk_rkbin_root)/tools/mkimage"
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
    local extension_dir secure_config_dir its_template

    extension_dir="$(resolve_rk_secure_extension_dir)"
    secure_config_dir="${extension_dir}/secure-boot-config"
    its_template="$(resolve_platform_its_template "${secure_config_dir}")"
    if [[ ! -f "${its_template}" ]]; then
        exit_with_error "FIT packaging failed: ITS template missing" "${secure_config_dir}"
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

#
# Build And Packaging Hooks
#

function build_custom_uboot__vendor_fit_secure() {
    # Use Rockchip vendor make.sh to build secure FIT version U-Boot.
    if ! rk_optee_bootchain_enabled; then
        return 0
    fi

    # Conditional restriction: Rockchip series (rockchip64 / rk35xx / downstream naming) or forced.
    if [[ ! "${LINUXFAMILY}" =~ ^(rockchip|rockchip64|rk35|rk35xx) ]]; then
        display_alert "secure-uboot" "LINUXFAMILY=${LINUXFAMILY} does not match Rockchip, skipping vendor FIT U-Boot build" "debug"
        return 0
    fi

    # Check for make.sh (vendor build flag)
    if [[ ! -f ./make.sh ]]; then
        display_alert "secure-uboot" "Vendor make.sh not found, falling back to standard build process" "warn"
        return 0
    fi

    # Prevent duplicate execution
    if [[ "${EXTENSION_BUILT_UBOOT}" == "yes" ]]; then
        display_alert "secure-uboot" "Marked EXTENSION_BUILT_UBOOT by other steps, skipping" "debug"
        return 0
    fi

    display_alert "secure-uboot" "Starting vendor FIT U-Boot build" "info"

    # Use standard patch process instead of manual copying
    display_alert "secure-uboot" "Applying standard patch process" "info"

    # Ensure uboot_git_revision is set (required by patch_uboot_target)
    declare -g uboot_git_revision
    if [[ -z "${uboot_git_revision}" ]]; then
        uboot_git_revision="$(git rev-parse HEAD)"
    fi

    # Apply standard patch process (this will automatically handle all patches in BOOTPATCHDIR)
    # Including: board_recomputer-rk3588/, target_*, common directories
    patch_uboot_target

    if rk_full_secure_boot_enabled; then
        # Full secure boot mode: apply secure defconfig/patch set (FIT-centric boot flow)
        apply_secure_boot_config
    else
        # OP-TEE bootchain mode: keep vendor default boot behavior, only ensure build chain is available
        display_alert "secure-uboot" "OP-TEE bootchain mode: skipping secure-boot defconfig/patch overlay" "info"
        if [[ -f .config ]]; then
            display_alert "secure-uboot" "OP-TEE bootchain mode: removing stale .config to avoid secure FIT boot behavior carry-over" "info"
            rm -f .config || exit_with_error "Failed to remove stale .config" "$(pwd)/.config"
        fi
        enable_optee_bootchain_bl32_fit_node
    fi
    setup_vendor_build_environment

    # Copy rkbin to the parent directory of u-boot
    local rkbin_source
    rkbin_source="$(resolve_platform_rkbin_dir)"
    local rkbin_dest="../rkbin"
    if [[ -d "${rkbin_source}" ]]; then
        display_alert "secure-uboot" "Copying platform rkbin (${rkbin_source}) to ${rkbin_dest}" "info"
        rm -rf "${rkbin_dest}" 2>/dev/null || true
        mkdir -p "${rkbin_dest}" || {
            display_alert "secure-uboot" "Failed to create ${rkbin_dest}" "err"
            return 1
        }
        cp -rf "${rkbin_source}/." "${rkbin_dest}/" || {
            display_alert "secure-uboot" "Failed to copy rkbin" "err"
            return 1
        }
    else
        exit_with_error "secure-uboot rkbin source directory does not exist (or platform unresolved)" "${rkbin_source}"
    fi

    # Copy prebuilts to the parent directory of u-boot
    local prebuilts_source="${SRC}/cache/sources/rockchip_sdk_tools/other_build_tool_chain/prebuilts"
    local prebuilts_dest="../prebuilts"
    if [[ -d "${prebuilts_source}" ]]; then
        display_alert "secure-uboot" "Copying prebuilts to ${prebuilts_dest}" "info"
        rm -rf "${prebuilts_dest}" 2>/dev/null || true
        cp -rf "${prebuilts_source}" "${prebuilts_dest}" || {
            display_alert "secure-uboot" "Failed to copy prebuilts" "err"
            return 1
        }
    else
        display_alert "secure-uboot" "prebuilts source directory does not exist: ${prebuilts_source}" "warn"
    fi

    # Build using vendor make.sh
    display_alert "secure-uboot" "Starting vendor u-boot compilation" "info"
    local vendor_board
    if [[ -n "${UBOOT_VENDOR_BOARD}" ]]; then
        vendor_board="${UBOOT_VENDOR_BOARD}"
    else
        case "$(detect_rk_secure_boot_platform)" in
            rk3576) vendor_board="recomputer-rk3576-devkit" ;;
            rk3588) vendor_board="recomputer-rk3588-devkit" ;;
            *) vendor_board="recomputer-rk3588-devkit" ;;
        esac
    fi
    bash ./make.sh "${vendor_board}" --spl-new || exit_with_error "vendor u-boot compilation failed" "make.sh"

    # Requires idblock support: generate idblock.bin
    display_alert "secure-uboot" "Generating idblock.bin" "info"
    bash ./make.sh --idblock || display_alert "secure-uboot" "idblock generation failed (continuing)" "warn"

    # Copy key files
    cp idblock.bin idbloader.img || true
    if [[ -f fit/uboot.itb ]]; then
        cp fit/uboot.itb u-boot.itb
    fi
    if [[ -f fit/u-boot.its ]]; then
        cp fit/u-boot.its u-boot.its
    fi
    rk_secure_boot_verify_fit_images "u-boot.itb"

    [[ -f rkspi_loader.img ]] ||
        exit_with_error "rkspi_loader.img missing after U-Boot postprocess" "expected rk-uboot-postprocess/rockchip64_common.inc output"
    display_alert "secure-uboot" "Using rkspi_loader.img from U-Boot postprocess" "info"

    # Collect artifacts to Armbian packaging directory
    collect_vendor_artifacts "${vendor_board}"

    # Mark as built
    EXTENSION_BUILT_UBOOT=yes
    uboot_target_counter=1
    display_alert "secure-uboot" "vendor FIT secure U-Boot build completed" "info"
    return 0
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
    local kernel_img_path="${kernel_src}/arch/arm64/boot/Image"
    local resource_path="${kernel_src}/resource.img"
    local fit_work="${TMPDIR:-/tmp}/fit-final-$$"
    local dtb_path

    display_alert "fit-post-initrd" "Starting to rebuild FIT before final unmount" "info"
    [[ -d "${boot_dir}" ]] || exit_with_error "FIT packaging failed: /boot does not exist" "${boot_dir}"

    rk_secure_boot_find_ramdisk "${boot_dir}"

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
