#!/bin/sh

OTA_PERSIST_USERDATA_LABEL="${OTA_PERSIST_USERDATA_LABEL:-armbi_usrdata}"

ota_persist_log() {
    if command -v log_info >/dev/null 2>&1; then
        log_info "persist: $*"
    elif command -v log >/dev/null 2>&1; then
        log "persist: $*"
    else
        echo "persist: $*" >&2
    fi
}

ota_persist_init_userdata() {
    root_mnt="$1"
    userdata_mnt="${2:-/mnt/userdata}"
    userdata_dev=""
    mounted_here=0

    [ -n "${root_mnt}" ] || {
        ota_persist_log "root mount path is empty, skip"
        return 0
    }

    userdata_dev="$(blkid -t LABEL="${OTA_PERSIST_USERDATA_LABEL}" -o device 2>/dev/null | head -n1 || true)"
    if [ -z "${userdata_dev}" ]; then
        ota_persist_log "userdata partition not found, skip"
        return 0
    fi

    mkdir -p "${userdata_mnt}" 2>/dev/null || true
    if mountpoint -q "${userdata_mnt}" 2>/dev/null; then
        ota_persist_log "reuse mounted userdata at ${userdata_mnt}"
    else
        if ! mount -t ext4 -o rw "${userdata_dev}" "${userdata_mnt}"; then
            ota_persist_log "failed to mount ${userdata_dev}, skip"
            return 0
        fi
        mounted_here=1
    fi

    persist="${userdata_mnt}/.persist"
    mkdir -p "${persist}/etc" "${persist}/home" 2>/dev/null || true

    for account_file in passwd shadow group gshadow subuid subgid; do
        if [ -f "${root_mnt}/etc/${account_file}" ] && [ ! -e "${persist}/etc/${account_file}" ]; then
            cp -a "${root_mnt}/etc/${account_file}" "${persist}/etc/${account_file}" 2>/dev/null || \
                ota_persist_log "failed to initialize ${account_file}"
        fi
    done

    if [ -d "${root_mnt}/home" ] && [ -z "$(ls -A "${persist}/home" 2>/dev/null)" ]; then
        cp -a "${root_mnt}/home/." "${persist}/home/" 2>/dev/null || \
            ota_persist_log "failed to initialize /home"
    fi

    chmod 755 "${persist}" "${persist}/etc" "${persist}/home" 2>/dev/null || true
    chmod 644 "${persist}/etc/passwd" "${persist}/etc/group" "${persist}/etc/subuid" "${persist}/etc/subgid" 2>/dev/null || true
    chmod 600 "${persist}/etc/shadow" "${persist}/etc/gshadow" 2>/dev/null || true

    sync
    if [ "${mounted_here}" -eq 1 ]; then
        umount "${userdata_mnt}" 2>/dev/null || ota_persist_log "failed to unmount ${userdata_mnt}"
    fi
    ota_persist_log "initialized /userdata/.persist account files and home data"
}
