#!/bin/bash

OTA_WORK_DIR="${OTA_WORK_DIR:-/ota_work}"
# Small/sensitive temp files (passphrase key, sha256 scratch) go to tmpfs so a
# crash never leaves them on disk. Payload extraction stays in OTA_WORK_DIR
# (on disk) to avoid OOM'ing RAM with the large rootfs.tar.gz.
OTA_TMP_DIR="${OTA_TMP_DIR:-/var/run/armbian-ota}"
OTA_LOCK_FILE="${OTA_LOCK_FILE:-/var/run/armbian-ota.lock}"
OTA_LOG_DIR="${OTA_LOG_DIR:-/var/log/armbian-ota}"
OTA_LOG_FILE="${OTA_LOG_FILE:-${OTA_LOG_DIR}/ota.log}"

# OTA package payload file names shared by A/B and recovery modes.
OTA_PAYLOAD_ROOTFS_TAR="rootfs.tar.gz"
OTA_PAYLOAD_ROOTFS_SHA="rootfs.sha256"
OTA_PAYLOAD_BOOT_TAR="boot.tar.gz"
OTA_PAYLOAD_BOOT_ITB="boot.itb"
OTA_PAYLOAD_BOOT_SHA="boot.sha256"
# Encrypted-payload artifacts (present when the package was built with
# CRYPTROOT_ENABLE=yes). Mirrors package-create.sh on the build side.
OTA_PAYLOAD_ROOTFS_ENC="rootfs.tar.gz.enc"
OTA_PAYLOAD_MANIFEST="payload.manifest"
OTA_PAYLOAD_MANIFEST_SIG="payload.manifest.sig"
OTA_PAYLOAD_KDF_INFO="armbian-ota-payload-v1"
OTA_PAYLOAD_PUBKEY="/usr/share/armbian-ota/keys/ota-payload.pub.pem"
# OP-TEE keybox_app writes the retrieved passphrase here (fixed path).
OTA_SYSPW_FILE="/tmp/syspw"

COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${COMMON_LIB_DIR}/state.sh"
unset COMMON_LIB_DIR

ota_source_library() {
    local library_path="$1"
    local library_name="$2"

    [ -r "${library_path}" ] || {
        echo "ERROR: ${library_name} not found: ${library_path}" >&2
        return 1
    }
    . "${library_path}"
}

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

extract_ota_package() {
    local package_path="$1"
    local dest_dir="$2"

    rm -rf "${dest_dir}"
    mkdir -p "${dest_dir}"
    tar -xzf "${package_path}" -C "${dest_dir}" || error_exit "Failed to extract OTA package: ${package_path}"
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

ota_is_fit_image() {
    local image="$1" magic

    [ -f "${image}" ] || return 1
    magic="$(dd if="${image}" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "${magic}" = "d00dfeed" ]
}

# ===== Encrypted payload: signature verification + decryption =====

# Read a key=value field from the payload manifest.
ota_manifest_get() {
    local key="$1" file="$2"
    awk -F= -v k="${key}" '$1==k {sub(/^[^=]*=/,""); print; exit}' "${file}" 2>/dev/null
}

# Locate the security partition holding the LUKS passphrase / SSKR marker.
ota_get_security_part() {
    local dev
    dev="$(blkid -t PARTLABEL=security -o device 2>/dev/null | head -n1)"
    [ -z "${dev}" ] && dev="$(blkid -t LABEL=security -o device 2>/dev/null | head -n1)"
    echo "${dev}"
}

# Retrieve the LUKS passphrase into out_file (mode 600). Read-only (no keybox
# migration): OTA only needs the current passphrase to derive the payload key.
# Mirrors the initramfs decryption-disk.sh raw / SSKR behavior.
ota_get_security_passphrase_file() {
    local out_file="$1"
    local security_dev marker tee_log keybox_log tee_pid

    [ -n "${out_file}" ] || return 1
    : > "${out_file}" || return 1
    chmod 600 "${out_file}" 2>/dev/null || true

    # Prefer the passphrase the initramfs stashed in /run. On NVMe (no RPMB),
    # keybox_app can't read rk_secure_storage in userspace; this reuses the
    # passphrase the initramfs already used to unlock root at boot.
    if [ -s /run/armbian-luks-passphrase ] && cp /run/armbian-luks-passphrase "${out_file}" 2>/dev/null; then
        chmod 600 "${out_file}" 2>/dev/null || true
        log_info "Using LUKS passphrase stashed by initramfs (/run/armbian-luks-passphrase)"
        return 0
    fi

    security_dev="$(ota_get_security_part)"
    [ -n "${security_dev}" ] || { log_error "Security partition not found"; return 1; }

    marker="$(head -c 4 "${security_dev}" 2>/dev/null || true)"
    log_info "Security partition marker: ${marker:-<empty>}"

    if [ "${marker}" = "SSKR" ]; then
        [ -x /usr/bin/keybox_app ] || { log_error "SSKR marker but /usr/bin/keybox_app missing"; return 1; }
        tee_log="$(make_ota_temp_file tee-supplicant)"
        keybox_log="$(make_ota_temp_file keybox)"
        if [ -x /usr/bin/tee-supplicant ]; then
            pkill -9 -x tee-supplicant >/dev/null 2>&1 || true
            sleep 1
            /usr/bin/tee-supplicant >"${tee_log}" 2>&1 &
            tee_pid="$!"
            sleep 1
        fi
        rm -f "${OTA_SYSPW_FILE}" 2>/dev/null || true
        if ! /usr/bin/keybox_app >"${keybox_log}" 2>&1; then
            [ -n "${tee_pid}" ] && kill "${tee_pid}" 2>/dev/null || true
            log_error "keybox_app read failed: $(tail -n1 "${keybox_log}" 2>/dev/null)"
            rm -f "${tee_log}" "${keybox_log}"
            return 1
        fi
        [ -n "${tee_pid}" ] && { kill "${tee_pid}" 2>/dev/null || true; wait "${tee_pid}" 2>/dev/null || true; }
        [ -s "${OTA_SYSPW_FILE}" ] || { log_error "keybox_app produced no passphrase"; rm -f "${tee_log}" "${keybox_log}"; return 1; }
        cp "${OTA_SYSPW_FILE}" "${out_file}" || { rm -f "${OTA_SYSPW_FILE}" "${tee_log}" "${keybox_log}"; return 1; }
        rm -f "${OTA_SYSPW_FILE}" "${tee_log}" "${keybox_log}"
        return 0
    fi

    # raw passphrase: first 64 bytes (the passphrase is a 64-char string).
    head -c 64 "${security_dev}" > "${out_file}" 2>/dev/null \
        || { log_error "Failed to read raw passphrase from ${security_dev}"; return 1; }
    return 0
}

# Derive the 32-byte AES-256 payload key (lowercase hex) from the LUKS
# passphrase via HKDF-SHA256. Identical derivation to the build-side
# ota_derive_payload_key_hex, so both sides agree from the same passphrase.
ota_hkdf_payload_key_hex() {
    local pass_file="$1"
    local ikm_hex info_hex
    [ -s "${pass_file}" ] || return 1
    ikm_hex="$(od -An -v -tx1 < "${pass_file}" | tr -d ' \n')"
    info_hex="$(printf '%s' "${OTA_PAYLOAD_KDF_INFO}" | od -An -v -tx1 | tr -d ' \n')"
    openssl kdf -keylen 32 -binary \
        -kdfopt digest:SHA256 -kdfopt key:"${ikm_hex}" -kdfopt info:"${info_hex}" \
        HKDF | od -An -v -tx1 | tr -d ' \n'
}

# Verify the manifest signature (if a signature + public key are present), then
# decrypt rootfs.tar.gz.enc into the plaintext tar name the rest of the pipeline
# expects, authenticating the result against the signed plaintext sha256.
ota_process_encrypted_payload() {
    local work_dir="$1"
    local rootfs_tar="$2"
    local enc_tar="${work_dir}/${OTA_PAYLOAD_ROOTFS_ENC}"
    local manifest="${work_dir}/${OTA_PAYLOAD_MANIFEST}"
    local sig="${work_dir}/${OTA_PAYLOAD_MANIFEST_SIG}"
    local plain_path="${work_dir}/${rootfs_tar}"
    local manifest_iv manifest_sha key_hex pass_file dec_sha

    ensure_command openssl
    [ -f "${manifest}" ] || error_exit "Encrypted payload missing ${OTA_PAYLOAD_MANIFEST}"

    if [ -f "${sig}" ]; then
        [ -f "${OTA_PAYLOAD_PUBKEY}" ] || error_exit "Signed OTA payload present but verification key missing: ${OTA_PAYLOAD_PUBKEY}"
        log_info "Verifying OTA payload manifest signature"
        openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
            -verify "${OTA_PAYLOAD_PUBKEY}" -signature "${sig}" "${manifest}" >/dev/null 2>&1 \
            || error_exit "OTA payload manifest signature verification failed"
        log_info "OTA payload manifest signature verified"
    else
        log_warn "Encrypted OTA payload has no signature; proceeding without authentication"
    fi

    manifest_iv="$(ota_manifest_get OTA_PAYLOAD_IV "${manifest}")"
    manifest_sha="$(ota_manifest_get OTA_PAYLOAD_ROOTFS_SHA256 "${manifest}")"
    [ -n "${manifest_iv}" ] || error_exit "Payload manifest missing OTA_PAYLOAD_IV"
    [ -n "${manifest_sha}" ] || error_exit "Payload manifest missing OTA_PAYLOAD_ROOTFS_SHA256"

    pass_file="$(make_ota_temp_file ota-pass)"
    chmod 600 "${pass_file}" 2>/dev/null || true
    if ! ota_get_security_passphrase_file "${pass_file}"; then
        rm -f "${pass_file}"
        error_exit "Failed to retrieve LUKS passphrase for payload decryption"
    fi
    if ! key_hex="$(ota_hkdf_payload_key_hex "${pass_file}")"; then
        rm -f "${pass_file}"
        error_exit "Failed to derive payload decryption key (HKDF)"
    fi
    rm -f "${pass_file}"

    log_info "Decrypting ${OTA_PAYLOAD_ROOTFS_ENC} -> ${rootfs_tar}"
    local oss_err="" rc=0
    oss_err="$(openssl enc -d -aes-256-cbc -K "${key_hex}" -iv "${manifest_iv}" \
        -in "${enc_tar}" -out "${plain_path}" 2>&1 >/dev/null)" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        [ -n "${oss_err}" ] && oss_err=": ${oss_err%%$'\n'*}"
        error_exit "Failed to decrypt OTA payload${oss_err} (wrong passphrase / corrupted blob / out of space)"
    fi

    dec_sha="$(sha256sum "${plain_path}" | awk '{print $1}')"
    [ "${dec_sha}" = "${manifest_sha}" ] \
        || error_exit "Decrypted payload SHA256 (${dec_sha}) does not match signed manifest (${manifest_sha})"

    log_info "OTA payload decrypted and authenticated (SHA256 matches signed manifest)"
}

ota_verify_payload() {
    local work_dir="$1"
    local rootfs_tar="$2"
    local rootfs_sha="$3"
    local boot_tar="$4"
    local boot_sha="$5"
    local boot_itb="$6"

    [ -f "${work_dir}/${boot_itb}" ] && [ -f "${work_dir}/${boot_tar}" ] &&
        error_exit "OTA package contains both ${boot_itb} and ${boot_tar}; refusing ambiguous boot payload"

    # Encrypted payload: authenticate + decrypt into the plaintext tar name
    # before normal archive verification proceeds.
    if [ -f "${work_dir}/${OTA_PAYLOAD_ROOTFS_ENC}" ]; then
        ota_process_encrypted_payload "${work_dir}" "${rootfs_tar}"
    fi

    verify_payload_archives "${work_dir}" "${rootfs_tar}" "${rootfs_sha}" "${boot_tar}" "${boot_sha}"

    if [ -f "${work_dir}/${boot_itb}" ]; then
        verify_sha256 "${work_dir}/${boot_itb}" "${work_dir}/${boot_sha}" "${boot_itb}"
        ota_is_fit_image "${work_dir}/${boot_itb}" ||
            error_exit "Invalid FIT boot image in OTA package: ${boot_itb}"
    fi
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
