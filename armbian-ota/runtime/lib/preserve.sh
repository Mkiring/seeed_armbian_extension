#!/bin/sh

OTA_PRESERVE_LIST="${OTA_PRESERVE_LIST:-/etc/armbian-ota/preserve-list.txt}"

ota_preserve_log_info() {
    if command -v log_info >/dev/null 2>&1; then
        log_info "preserve: $*"
    elif command -v log >/dev/null 2>&1; then
        log "preserve: $*"
    else
        echo "preserve: $*" >&2
    fi
}

ota_preserve_log_warn() {
    if command -v log_warn >/dev/null 2>&1; then
        log_warn "preserve: $*"
    elif command -v log >/dev/null 2>&1; then
        log "WARN: preserve: $*"
    else
        echo "WARN: preserve: $*" >&2
    fi
}

ota_preserve_log_tail() {
    prefix="$1"
    file="$2"
    lines="${3:-40}"

    if command -v log_tail >/dev/null 2>&1; then
        log_tail "preserve ${prefix}" "${file}" "${lines}"
    elif [ -s "${file}" ]; then
        tail -n "${lines}" "${file}" 2>/dev/null | while IFS= read -r line; do
            ota_preserve_log_warn "${prefix}: ${line}"
        done
    fi
}

ota_preserve_trim_path() {
    echo "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

ota_preserve_is_safe_absolute_path() {
    case "$1" in
        /*) ;;
        *)
            ota_preserve_log_warn "skip non-absolute path: $1"
            return 1
            ;;
    esac

    case "$1" in
        "/"|"/."|"/.."|*"../"*|*"/.."|*"*"*|*"?"*|*"["*|*"]"*)
            ota_preserve_log_warn "skip unsafe pattern: $1"
            return 1
            ;;
    esac

    return 0
}

ota_preserve_copy_path() {
    src_root="$1"
    dst_root="$2"
    rel="$3"
    src="${src_root%/}/${rel}"
    dst="${dst_root%/}/${rel}"
    dst_parent="$(dirname "${dst}")"

    if [ ! -e "${src}" ] && [ ! -L "${src}" ]; then
        ota_preserve_log_info "source path not found, skip: /${rel}"
        return 0
    fi

    mkdir -p "${dst_parent}" 2>/dev/null || {
        ota_preserve_log_warn "failed to create target parent: ${dst_parent}"
        return 0
    }

    rm -rf "${dst}" 2>/dev/null || true
    if cp -a "${src}" "${dst_parent}/" 2>/dev/null; then
        ota_preserve_log_info "copied /${rel}"
    else
        ota_preserve_log_warn "failed to copy /${rel}"
    fi
}

ota_preserve_apply_list() {
    src_root="$1"
    dst_root="$2"
    list_file="${3:-${OTA_PRESERVE_LIST}}"
    raw=""
    line=""
    rel=""

    [ -n "${src_root}" ] || {
        ota_preserve_log_warn "source root is empty, skip"
        return 0
    }
    [ -n "${dst_root}" ] || {
        ota_preserve_log_warn "target root is empty, skip"
        return 0
    }
    [ -f "${list_file}" ] || {
        ota_preserve_log_info "list not found: ${list_file}, skip"
        return 0
    }

    ota_preserve_log_info "applying ${list_file} from ${src_root} to ${dst_root}"
    while IFS= read -r raw || [ -n "${raw}" ]; do
        line="$(ota_preserve_trim_path "${raw}")"
        case "${line}" in
            ""|\#*) continue ;;
        esac
        ota_preserve_is_safe_absolute_path "${line}" || continue

        rel="${line#/}"
        [ -n "${rel}" ] || continue
        ota_preserve_copy_path "${src_root}" "${dst_root}" "${rel}"
    done < "${list_file}"
}

ota_preserve_prepare_archive_list() {
    root_dir="$1"
    list_file="$2"
    tmp_list="$3"
    raw=""
    line=""
    rel=""
    target=""

    rm -f "${tmp_list}" 2>/dev/null || true
    [ -f "${list_file}" ] || {
        ota_preserve_log_info "list not found: ${list_file}, skip preserve step"
        return 1
    }

    while IFS= read -r raw || [ -n "${raw}" ]; do
        line="$(ota_preserve_trim_path "${raw}")"
        case "${line}" in
            ""|\#*) continue ;;
        esac
        ota_preserve_is_safe_absolute_path "${line}" || continue

        rel="${line#/}"
        [ -n "${rel}" ] || continue
        target="${root_dir%/}/${rel}"
        if [ -e "${target}" ] || [ -L "${target}" ]; then
            printf '%s\n' "${rel}" >> "${tmp_list}"
        else
            ota_preserve_log_info "path not found, skip: ${line}"
        fi
    done < "${list_file}"

    if [ ! -s "${tmp_list}" ]; then
        ota_preserve_log_info "no valid entries found in ${list_file}"
        rm -f "${tmp_list}" 2>/dev/null || true
        return 1
    fi

    return 0
}

ota_preserve_backup_archive() {
    root_dir="$1"
    list_file="$2"
    archive="$3"
    tmp_list="$4"
    log_dir="${5:-${OTA_WORK_DIR:-/tmp}}"
    err_file="${log_dir}/preserve.backup.stderr.log"
    rc=0

    rm -f "${archive}" "${err_file}" 2>/dev/null || true
    ota_preserve_prepare_archive_list "${root_dir}" "${list_file}" "${tmp_list}" || return 0
    ota_preserve_log_info "backing up whitelisted files to ${archive}"

    # BusyBox tar lacks -T, so expand the validated archive list into
    # positional arguments. This also works with GNU tar.
    set --
    while IFS= read -r rel || [ -n "${rel}" ]; do
        [ -n "${rel}" ] && set -- "$@" "${rel}"
    done < "${tmp_list}"
    [ "$#" -gt 0 ] || return 0

    if tar --xattrs --acls --numeric-owner -cpf "${archive}" -C "${root_dir}" "$@" 2>"${err_file}"; then
        ota_preserve_log_info "backup completed (metadata mode)"
        rm -f "${err_file}" 2>/dev/null || true
        return 0
    else
        rc=$?
    fi

    ota_preserve_log_info "metadata backup failed rc=${rc}, retry plain tar mode"
    ota_preserve_log_tail "backup stderr" "${err_file}" 40

    rm -f "${err_file}" 2>/dev/null || true
    if tar -cpf "${archive}" -C "${root_dir}" "$@" 2>"${err_file}"; then
        ota_preserve_log_info "backup completed (plain mode)"
        rm -f "${err_file}" 2>/dev/null || true
        return 0
    else
        rc=$?
    fi

    ota_preserve_log_warn "backup failed rc=${rc}, continue without preserve"
    ota_preserve_log_tail "backup stderr" "${err_file}" 60
    rm -f "${archive}" "${tmp_list}" "${err_file}" 2>/dev/null || true
    return 0
}

ota_preserve_restore_archive() {
    root_dir="$1"
    archive="$2"
    tmp_list="$3"

    if [ ! -f "${archive}" ]; then
        ota_preserve_log_info "no backup archive found, skip restore"
        return 0
    fi

    ota_preserve_log_info "restoring whitelisted files from ${archive}"
    if command -v start_heartbeat >/dev/null 2>&1; then
        start_heartbeat "restoring preserved files"
    fi

    if command -v extract_tar_with_fallback >/dev/null 2>&1; then
        extract_tar_with_fallback "${archive}" "${root_dir}" "preserve"
        rc=$?
    else
        tar --xattrs --acls --numeric-owner -xpf "${archive}" -C "${root_dir}" 2>/dev/null ||
            tar -xpf "${archive}" -C "${root_dir}" 2>/dev/null
        rc=$?
    fi

    if command -v stop_heartbeat >/dev/null 2>&1; then
        stop_heartbeat
    fi

    if [ "${rc}" -ne 0 ]; then
        ota_preserve_log_warn "restore failed, continue OTA"
        rm -f "${archive}" "${tmp_list}" 2>/dev/null || true
        return 0
    fi

    rm -f "${archive}" "${tmp_list}" 2>/dev/null || true
    ota_preserve_log_info "restore completed"
    return 0
}
