#
# Shared Rockchip secure boot / auto decryption helpers
#

function rk_run_host_command() {
    if [[ "$(type -t run_host_command_logged || true)" == "function" ]]; then
        run_host_command_logged "$@"
    else
        "$@"
    fi
}

function rk_fetch_sdk_tools() {
    fetch_from_repo "${RKBIN_GIT_URL:-"https://github.com/ackPeng/rockchip_sdk_tools.git"}" "rockchip_sdk_tools" "branch:${RKSDK_TOOLS_BRANCH:-"main"}"
}

function rk_sdk_tools_root() {
    echo "${SRC}/cache/sources/rockchip_sdk_tools"
}

function rk_sdk_rkbin_root() {
    echo "$(rk_sdk_tools_root)/rkbin"
}

function rk_ensure_sdk_tools() {
    local alert_label="${1:-rockchip-sdk-tools}"
    local sdk_tools_root
    sdk_tools_root="$(rk_sdk_tools_root)"

    if [[ ! -d "${sdk_tools_root}" ]]; then
        display_alert "${alert_label}" "rockchip_sdk_tools source directory not found, downloading" "info"
        rk_fetch_sdk_tools
    fi
}

function rk_full_secure_boot_enabled() {
    [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" ]]
}

function rk_optee_bootchain_enabled() {
    rk_full_secure_boot_enabled || [[ "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]
}

function rk_autodecrypt_enabled() {
    [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]
}

function rk_autodecrypt_nonsecure_mode_enabled() {
    rk_autodecrypt_enabled && ! rk_full_secure_boot_enabled
}

function rk_autodecrypt_fit_boot_required() {
    rk_full_secure_boot_enabled ||
        { rk_autodecrypt_enabled && [[ "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; }
}

function rk_platform_from_name() {
    local name
    name="$(echo "$*" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr ' ' '-')"

    case "${name}" in
        *rk3576*|*3576*) echo "rk3576" ;;
        *rk3588*|*3588*) echo "rk3588" ;;
        *) echo "unknown" ;;
    esac
}

function rk_default_vendor_board() {
    local platform="$1"

    case "${platform}" in
        rk3576|rk3588) echo "recomputer-${platform}-devkit" ;;
        *) echo "unknown" ;;
    esac
}

function rk_detect_platform() {
    local platform

    platform="$(rk_platform_from_name "${BOOT_SOC:-}")"
    if [[ "${platform}" != "unknown" ]]; then
        echo "${platform}"
        return 0
    fi

    rk_platform_from_name "${BOARD_NAME:-${BOARD:-}}"
}

function rk_detect_vendor_board() {
    rk_default_vendor_board "$(rk_detect_platform)"
}

function rk_resolve_extension_dir() {
    local required_subdir="$1"
    local script_dir candidate
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    for candidate in \
        "${script_dir}" \
        "${SRC}/extensions/seeed_armbian_extension/rk_secure-disk-encryption" \
        "${SRC}/extensions/rk_secure-disk-encryption"; do
        if [[ -d "${candidate}/${required_subdir}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done

    echo "${script_dir}"
}
