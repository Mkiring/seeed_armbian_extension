# Secure boot U-Boot build hook helpers
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
    rk_secure_kernel_fit_template_path || true
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
function rk_secure_boot_stage_uboot_fit_generator() {
    local uboot_workdir="$1"
    local generator_src generator_dst

    generator_src="$(rk_secure_uboot_fit_generator_path)" ||
        exit_with_error "Secure U-Boot FIT generator missing" "$(rk_resolve_extension_dir "u-boot/fit-generator")/u-boot/fit-generator/make_fit_atf_optee.sh"
    generator_dst="${uboot_workdir}/arch/arm/mach-rockchip/make_fit_atf_optee.sh"

    install -m 0755 "${generator_src}" "${generator_dst}" ||
        exit_with_error "Failed to stage U-Boot FIT generator" "${generator_dst}"
}

function rk_secure_boot_apply_config_fragment() {
    local fragment="$1"

    rk_apply_kconfig_fragment scripts/config "${fragment}" ||
        exit_with_error "Failed to apply secure U-Boot config fragment" "${fragment}"
    display_alert "secure-uboot" "Applied U-Boot config fragment: ${fragment}" "info"
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

function rk_secure_boot_check_produced_fit_image() {
    if ! rk_optee_bootchain_enabled; then
        return 0
    fi

    [[ "${base_binfile}" == "u-boot.itb" ]] || return 0
    rk_secure_boot_verify_fit_images "${binfile}"
}

function rk_secure_boot_prepare_uboot_tree() {
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

    rk_secure_boot_stage_uboot_fit_generator "${uboot_workdir}"

    rkbin_root="$(rk_sdk_rkbin_root)"
    rkbin_dir="$(resolve_platform_rkbin_dir)"
    display_alert "secure-uboot" "rkbin root: ${rkbin_root}" "debug"
    display_alert "secure-uboot" "platform rkbin: ${rkbin_dir:-<not found>}" "debug"
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
