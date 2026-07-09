#!/bin/sh

OTA_PERSIST_USERDATA_LABEL="${OTA_PERSIST_USERDATA_LABEL:-armbi_usrdata}"
OTA_PERSIST_MAP="${OTA_PERSIST_MAP:-/etc/armbian-ota/persist-map.txt}"

ota_persist_log() {
    if command -v log_info >/dev/null 2>&1; then
        log_info "persist: $*"
    elif command -v log >/dev/null 2>&1; then
        log "persist: $*"
    else
        echo "persist: $*" >&2
    fi
}

ota_persist_trim_line() {
    echo "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

ota_persist_is_safe_absolute_path() {
    case "$1" in
        /*) ;;
        *)
            ota_persist_log "skip non-absolute path: $1"
            return 1
            ;;
    esac

    case "$1" in
        "/"|"/."|"/.."|*"../"*|*"/.."|*"*"*|*"?"*|*"["*|*"]"*)
            ota_persist_log "skip unsafe path: $1"
            return 1
            ;;
    esac

    return 0
}

ota_persist_map_file() {
    root_mnt="$1"
    map_file="${2:-}"

    if [ -n "${map_file}" ]; then
        echo "${map_file}"
    elif [ -f "${root_mnt%/}${OTA_PERSIST_MAP}" ]; then
        echo "${root_mnt%/}${OTA_PERSIST_MAP}"
    elif [ -f "${OTA_PERSIST_MAP}" ]; then
        echo "${OTA_PERSIST_MAP}"
    else
        echo ""
    fi
}

ota_persist_source_path() {
    root_mnt="$1"
    userdata_mnt="$2"
    persist_src="$3"

    case "${persist_src}" in
        /userdata/*)
            if mountpoint -q "${userdata_mnt}" 2>/dev/null; then
                echo "${userdata_mnt%/}/${persist_src#/userdata/}"
            else
                echo "${root_mnt%/}${persist_src}"
            fi
            ;;
        *)
            echo "${root_mnt%/}${persist_src}"
            ;;
    esac
}

ota_persist_init_path() {
    root_mnt="$1"
    userdata_mnt="$2"
    persist_src="$3"
    mount_target="$4"
    persist_path="$(ota_persist_source_path "${root_mnt}" "${userdata_mnt}" "${persist_src}")"
    target_path="${root_mnt%/}${mount_target}"

    mkdir -p "${persist_path}" 2>/dev/null || {
        ota_persist_log "failed to create ${persist_src}"
        return 0
    }

    if [ -d "${target_path}" ] && [ -z "$(ls -A "${persist_path}" 2>/dev/null)" ]; then
        cp -a "${target_path}/." "${persist_path}/" 2>/dev/null || \
            ota_persist_log "failed to initialize ${persist_src} from ${mount_target}"
    fi

    chmod 755 "${persist_path}" 2>/dev/null || true
}

ota_persist_init_userdata() {
    root_mnt="$1"
    userdata_mnt="${2:-/mnt/userdata}"
    map_file="$(ota_persist_map_file "${root_mnt}" "${3:-}")"
    userdata_dev=""
    mounted_here=0
    raw=""
    line=""
    persist_src=""
    mount_target=""

    [ -n "${root_mnt}" ] || {
        ota_persist_log "root mount path is empty, skip"
        return 0
    }

    userdata_dev="$(blkid -t LABEL="${OTA_PERSIST_USERDATA_LABEL}" -o device 2>/dev/null | head -n1 || true)"
    if [ -n "${userdata_dev}" ]; then
        mkdir -p "${userdata_mnt}" 2>/dev/null || true
        if mountpoint -q "${userdata_mnt}" 2>/dev/null; then
            ota_persist_log "reuse mounted userdata at ${userdata_mnt}"
        else
            if mount -t ext4 -o rw "${userdata_dev}" "${userdata_mnt}"; then
                mounted_here=1
            else
                ota_persist_log "failed to mount ${userdata_dev}, use rootfs paths"
            fi
        fi
    fi

    if [ -f "${map_file}" ]; then
        while IFS= read -r raw || [ -n "${raw}" ]; do
            line="$(ota_persist_trim_line "${raw}")"
            case "${line}" in
                ""|\#*) continue ;;
            esac
            persist_src="${line%%[[:space:]]*}"
            mount_target="${line#${persist_src}}"
            mount_target="$(ota_persist_trim_line "${mount_target}")"
            mount_target="${mount_target%%[[:space:]]*}"

            ota_persist_is_safe_absolute_path "${persist_src}" || continue
            ota_persist_is_safe_absolute_path "${mount_target}" || continue
            ota_persist_init_path "${root_mnt}" "${userdata_mnt}" "${persist_src}" "${mount_target}"
        done < "${map_file}"
    else
        ota_persist_log "persist map not found, use default /home mapping"
        ota_persist_init_path "${root_mnt}" "${userdata_mnt}" "/userdata/.persist/home" "/home"
    fi

    sync
    if [ "${mounted_here}" -eq 1 ]; then
        umount "${userdata_mnt}" 2>/dev/null || ota_persist_log "failed to unmount ${userdata_mnt}"
    fi
    ota_persist_log "initialized userdata persist data"
}
