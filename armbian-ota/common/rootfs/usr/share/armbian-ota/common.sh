#!/bin/bash

OTA_WORK_DIR="${OTA_WORK_DIR:-/ota_work}"
# Small/sensitive temp files (passphrase key, sha256 scratch) go to tmpfs so a
# crash never leaves them on disk. Payload extraction stays in OTA_WORK_DIR
# (on disk) to avoid OOM'ing RAM with the large rootfs.tar.gz.
OTA_TMP_DIR="${OTA_TMP_DIR:-/var/run/armbian-ota}"
OTA_LOCK_FILE="${OTA_LOCK_FILE:-/var/run/armbian-ota.lock}"
OTA_LOG_DIR="${OTA_LOG_DIR:-/var/log/armbian-ota}"
OTA_LOG_FILE="${OTA_LOG_FILE:-${OTA_LOG_DIR}/ota.log}"

COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${COMMON_LIB_DIR}/state.sh"
unset COMMON_LIB_DIR

init_logging() {
    mkdir -p "${OTA_LOG_DIR}" "${OTA_STATE_DIR}"
}

log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] $*" | tee -a "${OTA_LOG_FILE}" 2>/dev/null
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_error() {
    log "ERROR" "$@"
}

error_exit() {
    log_error "$@"
    exit 1
}

ensure_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        error_exit "This command must be run as root"
    fi
}

release_lock() {
    rm -f "${OTA_LOCK_FILE}" 2>/dev/null
}

acquire_lock() {
    if [ -f "${OTA_LOCK_FILE}" ]; then
        local lock_pid
        lock_pid="$(cat "${OTA_LOCK_FILE}" 2>/dev/null)"
        if [ -n "${lock_pid}" ] && kill -0 "${lock_pid}" 2>/dev/null; then
            log_error "Another OTA process is running (PID: ${lock_pid})"
            return 1
        fi
        log_warn "Removing stale lock file"
        rm -f "${OTA_LOCK_FILE}"
    fi

    echo $$ > "${OTA_LOCK_FILE}"
    trap 'release_lock' EXIT
}

ensure_command() {
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || error_exit "Missing required command: ${cmd}"
    done
}

ota_require_runtime() {
    ensure_root
    init_logging
    ensure_command "$@"
    acquire_lock || error_exit "Cannot acquire OTA lock"
}

empty_mount_dir() {
    local mount_dir="$1" f

    (
        cd "${mount_dir}" || exit 1
        for f in * .[!.]* ..?*; do
            case "${f}" in
                .|..|lost+found) continue ;;
            esac
            rm -rf "${f}" 2>/dev/null || exit 1
        done
    )
}

load_package_env_metadata() {
    local package_path="$1"
    local manifest_entry

    if [ "${OTA_PACKAGE_ENV_PATH:-}" = "${package_path}" ] && [ -n "${OTA_PACKAGE_ENV_CONTENT+x}" ]; then
        return 0
    fi

    log_info "Reading OTA package metadata from ${package_path}" >&2
    manifest_entry="$(
        tar -tzf "${package_path}" 2>/dev/null \
            | awk '/(^|\/)package\.env$/ { print; exit }'
    )"
    if [ -z "${manifest_entry}" ]; then
        return 1
    fi

    OTA_PACKAGE_ENV_PATH="${package_path}"
    OTA_PACKAGE_ENV_CONTENT="$(tar -xOf "${package_path}" "${manifest_entry}" 2>/dev/null)" || return 1
}

package_env_get_value() {
    local key="$1"

    printf '%s\n' "${OTA_PACKAGE_ENV_CONTENT:-}" \
        | grep -E "^${key}=" | tail -n1 | cut -d'=' -f2-
}

read_package_env_value() {
    local package_path="$1"
    local key="$2"

    load_package_env_metadata "${package_path}" || return 1
    package_env_get_value "${key}"
}

assert_package_mode_matches() {
    local package_path="$1"
    local expected_mode="$2"
    local manifest_mode

    manifest_mode="$(read_package_env_value "${package_path}" "OTA_MODE" || true)"
    if [ -z "${manifest_mode}" ]; then
        error_exit "OTA package metadata missing OTA_MODE; refusing to continue"
    fi

    case "${manifest_mode}" in
        ab|recovery) ;;
        *)
            error_exit "Invalid OTA_MODE in package metadata: ${manifest_mode} (expected ab or recovery)"
            ;;
    esac

    case "${expected_mode}" in
        ab|recovery) ;;
        *) error_exit "Invalid requested OTA mode: ${expected_mode}" ;;
    esac

    if [ "${manifest_mode}" != "${expected_mode}" ]; then
        error_exit "OTA package mode mismatch: expected ${expected_mode}, manifest=${manifest_mode}"
    fi
}

verify_sha256() {
    local payload="$1"
    local sha_file="$2"
    local label="${3:-payload}"

    [ -f "${payload}" ] || error_exit "Missing ${label}: ${payload}"
    [ -f "${sha_file}" ] || error_exit "Missing checksum file: ${sha_file}"
    ensure_command sha256sum

    local payload_dir payload_base sha_path check_file tmp_sha
    payload_dir="$(cd "$(dirname "${payload}")" && pwd)"
    payload_base="$(basename "${payload}")"
    sha_path="$(cd "$(dirname "${sha_file}")" && pwd)/$(basename "${sha_file}")"
    check_file="${sha_path}"
    tmp_sha=""

    if ! grep -qE "[[:space:]]${payload_base}$" "${sha_path}"; then
        tmp_sha="$(make_ota_temp_file "sha256")"
        awk -v f="${payload_base}" '{print $1"  "f}' "${sha_path}" > "${tmp_sha}" || {
            rm -f "${tmp_sha}"
            error_exit "Failed to rewrite checksum file for ${label}"
        }
        check_file="${tmp_sha}"
    fi

    log_info "Verifying ${label} checksum"
    (cd "${payload_dir}" && sha256sum -c "${check_file}" >/dev/null 2>&1) || {
        [ -n "${tmp_sha}" ] && rm -f "${tmp_sha}"
        error_exit "${label} checksum verification failed"
    }
    [ -n "${tmp_sha}" ] && rm -f "${tmp_sha}"
}

verify_payload_archives() {
    local work_dir="$1"
    local rootfs_tar="$2"
    local rootfs_sha="$3"
    local boot_tar="$4"
    local boot_sha="$5"

    verify_sha256 "${work_dir}/${rootfs_tar}" "${work_dir}/${rootfs_sha}" "${rootfs_tar}"

    if [ -f "${work_dir}/${boot_tar}" ]; then
        verify_sha256 "${work_dir}/${boot_tar}" "${work_dir}/${boot_sha}" "${boot_tar}"
    fi
}

extract_ota_package() {
    local package_path="$1"
    local dest_dir="$2"

    rm -rf "${dest_dir}"
    mkdir -p "${dest_dir}"
    tar -xzf "${package_path}" -C "${dest_dir}" || error_exit "Failed to extract OTA package: ${package_path}"
}

make_ota_work_dir() {
    local prefix="${1:-work}"

    mkdir -p "${OTA_WORK_DIR}" || error_exit "Failed to create OTA work directory: ${OTA_WORK_DIR}"
    mktemp -d "${OTA_WORK_DIR}/${prefix}.XXXXXX" || error_exit "Failed to create OTA temporary directory under ${OTA_WORK_DIR}"
}

make_ota_temp_file() {
    local prefix="${1:-tmp}"

    mkdir -p "${OTA_TMP_DIR}" || error_exit "Failed to create OTA temp directory: ${OTA_TMP_DIR}"
    mktemp "${OTA_TMP_DIR}/${prefix}.XXXXXX" || error_exit "Failed to create OTA temporary file under ${OTA_TMP_DIR}"
}
