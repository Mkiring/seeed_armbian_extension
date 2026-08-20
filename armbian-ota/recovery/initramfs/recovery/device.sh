#!/bin/sh
#
# Recovery initramfs source: block device / partition / UUID / LUKS / FIT probing.
#
# Sourced by 99-ota-apply after recovery/log.sh (primitives are silent; only
# ota_detect_devices logs). /bin/sh + busybox (blkid, udevadm).

# ===== helper: get DEV + UUID by LABEL (e.g. /dev/mmcblk0p5 + UUID) =====
get_dev_and_uuid_by_label() {
    label="$1"
    dev="$(blkid -t LABEL="${label}" -o device 2>/dev/null | head -n1)"
    [ -n "${dev}" ] || return 1
    uuid="$(blkid -s UUID -o value "${dev}" 2>/dev/null | head -n1)"
    [ -n "${uuid}" ] || return 1
    printf '%s %s\n' "${dev}" "${uuid}"
}

get_uuid_by_label() {
    set -- $(get_dev_and_uuid_by_label "$1" 2>/dev/null) || return 1
    [ -n "$2" ] || return 1
    printf '%s\n' "$2"
}

# ===== helper: get LUKS UUID for encrypted root backing device =====
get_luks_uuid_for_root() {
    local root_luks_dev

    root_luks_dev="$(blkid -t PARTLABEL=rootfs -o device 2>/dev/null | head -n1 || true)"
    if [ -n "${root_luks_dev}" ] && [ "$(blkid -s TYPE -o value "${root_luks_dev}" 2>/dev/null || true)" = "crypto_LUKS" ]; then
        blkid -s UUID -o value "${root_luks_dev}" 2>/dev/null | head -n1
        return 0
    fi

    blkid -t TYPE=crypto_LUKS -s UUID -o value 2>/dev/null | head -n1
}

get_partname_for_dev() {
    dev="$1"
    base="$(basename "${dev}")"
    uevent="/sys/class/block/${base}/uevent"

    [ -f "${uevent}" ] || return 1
    sed -n 's/^PARTNAME=//p' "${uevent}" | head -n1
}

find_raw_boot_dev() {
    for uevent in /sys/class/block/*/uevent; do
        [ -f "${uevent}" ] || continue
        devname="$(sed -n 's/^DEVNAME=//p' "${uevent}" | head -n1)"
        partname="$(sed -n 's/^PARTNAME=//p' "${uevent}" | head -n1)"
        [ -n "${devname}" ] || continue
        [ "${partname}" = "boot" ] || continue
        printf '/dev/%s\n' "${devname}"
        return 0
    done
    return 1
}

blockdev_size_bytes() {
    dev="$1"
    base="$(basename "${dev}")"
    sectors_file="/sys/class/block/${base}/size"

    [ -f "${sectors_file}" ] || return 1
    sectors="$(cat "${sectors_file}" 2>/dev/null)"
    [ -n "${sectors}" ] || return 1
    echo $((sectors * 512))
}

file_size_bytes() {
    file="$1"

    wc -c < "${file}" 2>/dev/null | awk '{print $1}'
}

is_fit_image() {
    file="$1"

    magic="$(dd if="${file}" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "${magic}" = "d00dfeed" ]
}

# ===== detect firmware mode and root/boot devices =====
# Sets globals: ROOT_DEV, ROOT_UUID, BOOT_DEV, BOOT_UUID, HAS_BOOT_PART,
# AUTO_DECRYPT_MODE. ROOT_DEV stays empty when detection fails (caller skips).
ota_detect_devices() {
    ROOT_DEV=""
    ROOT_UUID=""
    BOOT_DEV=""
    BOOT_UUID=""
    HAS_BOOT_PART=0
    AUTO_DECRYPT_MODE=0

    # Wait for block devices to settle before probing. In init-premount the root
    # partition node may not have appeared yet (mmc scan can lag the hook by ~1s),
    # which previously made blkid miss LABEL=armbi_root and silently skip OTA.
    udevadm settle --timeout=10 2>/dev/null || true

    # Detect auto-decrypt by mapper first. Some minimal images do not ship blkid in
    # the real rootfs, but initramfs only needs the already-opened mapper.
    if [ -e /dev/mapper/armbian-root ] || blkid -t TYPE=crypto_LUKS >/dev/null 2>&1; then
        log "auto-decrypt candidate detected, waiting for /dev/mapper/armbian-root"
        timeout=30
        elapsed=0
        while [ ! -e /dev/mapper/armbian-root ] && [ "${elapsed}" -lt "${timeout}" ]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
        if [ -e /dev/mapper/armbian-root ]; then
            AUTO_DECRYPT_MODE=1
            ROOT_DEV="/dev/mapper/armbian-root"
            ROOT_UUID="$(get_luks_uuid_for_root || true)"
            log "auto-decrypt mode: ROOT_DEV=${ROOT_DEV}, LUKS_UUID=${ROOT_UUID:-<empty>}"
        else
            log "WARN: LUKS container present but mapper not ready after ${timeout}s, fallback to standard mode"
        fi
    else
        log "no crypto_LUKS container, using standard recovery OTA mode"
    fi

    boot_info="$(get_dev_and_uuid_by_label "armbi_boot" || true)"

    if [ "${AUTO_DECRYPT_MODE}" -eq 0 ]; then
        # Standard mode root detection. Prefer /proc/cmdline root= (always present,
        # independent of device probe timing), fall back to LABEL=armbi_root.
        root_info=""
        cmdline_root=""
        for _tok in $(cat /proc/cmdline 2>/dev/null); do
            case "${_tok}" in
                root=*) cmdline_root="${_tok#root=}"; break ;;
            esac
        done

        if [ -n "${cmdline_root}" ]; then
            log "cmdline root= detected: ${cmdline_root}"
            case "${cmdline_root}" in
                UUID=*)
                    _cuuid="${cmdline_root#UUID=}"
                    _cdev=""
                    _i=0
                    while [ "${_i}" -lt 10 ]; do
                        _cdev="$(blkid -U "${_cuuid}" 2>/dev/null)" && [ -n "${_cdev}" ] && break
                        sleep 1
                        _i=$((_i + 1))
                    done
                    if [ -n "${_cdev}" ]; then
                        root_info="${_cdev} ${_cuuid}"
                    else
                        log "WARN: cmdline root=UUID=${_cuuid} unresolved after 10s, fallback to LABEL"
                    fi
                    ;;
                LABEL=*)
                    _clbl="${cmdline_root#LABEL=}"
                    _cinfo="$(get_dev_and_uuid_by_label "${_clbl}" || true)"
                    [ -n "${_cinfo}" ] && root_info="${_cinfo}"
                    ;;
                /dev/*)
                    _cdev="${cmdline_root}"
                    _cuuid="$(blkid -s UUID -o value "${_cdev}" 2>/dev/null | head -n1)"
                    root_info="${_cdev} ${_cuuid}"
                    ;;
                *)
                    log "WARN: cmdline root= format not recognized: ${cmdline_root}"
                    ;;
            esac
        fi

        if [ -z "${root_info}" ]; then
            log "cmdline root= unavailable or unresolved, fallback to LABEL=armbi_root"
            root_info="$(get_dev_and_uuid_by_label "armbi_root" || true)"
        fi

        if [ -n "${root_info}" ]; then
            set -- $root_info
            ROOT_DEV="$1"
            ROOT_UUID="$2"
        fi
        log "standard mode root detection: ROOT_DEV=${ROOT_DEV}, ROOT_UUID=${ROOT_UUID}"
    else
        log "auto-decrypt mode root detection: skip armbi_root label probing"
    fi

    if [ -n "$boot_info" ]; then
        set -- $boot_info
        BOOT_DEV="$1"
        BOOT_UUID="$2"
        HAS_BOOT_PART=1
    fi

    log "auto-detected BOOT_DEV=${BOOT_DEV}, BOOT_UUID=${BOOT_UUID}, HAS_BOOT_PART=${HAS_BOOT_PART}"
}
