#!/bin/sh

OTA_PRESERVE_LIST="${OTA_PRESERVE_LIST:-/etc/armbian-ota/back-list.txt}"

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
        line="$(echo "${raw}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "${line}" in
            ""|\#*) continue ;;
        esac
        case "${line}" in
            /*) ;;
            *)
                ota_preserve_log_warn "skip non-absolute path: ${line}"
                continue
                ;;
        esac
        case "${line}" in
            "/"|"/."|"/.."|*"../"*|*"/.."|*"*"*|*"?"*|*"["*|*"]"*)
                ota_preserve_log_warn "skip unsafe pattern: ${line}"
                continue
                ;;
        esac

        rel="${line#/}"
        [ -n "${rel}" ] || continue
        ota_preserve_copy_path "${src_root}" "${dst_root}" "${rel}"
    done < "${list_file}"
}
