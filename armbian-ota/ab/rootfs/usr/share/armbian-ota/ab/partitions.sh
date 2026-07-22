# A/B slot topology and partition discovery helpers.

BOOT_A_LABEL="armbi_boota"
BOOT_B_LABEL="armbi_bootb"
ROOT_A_LABEL="armbi_roota"
ROOT_B_LABEL="armbi_rootb"

ab_other_slot() {
    case "$1" in
        a) echo "b" ;;
        b) echo "a" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_boot_label() {
    case "$1" in
        a) echo "${BOOT_A_LABEL}" ;;
        b) echo "${BOOT_B_LABEL}" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_root_label() {
    case "$1" in
        a) echo "${ROOT_A_LABEL}" ;;
        b) echo "${ROOT_B_LABEL}" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_boot_partlabel() {
    case "$1" in
        a) echo "boot_a" ;;
        b) echo "boot_b" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_root_partlabel() {
    case "$1" in
        a) echo "rootfs_a" ;;
        b) echo "rootfs_b" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_by_label() {
    case "$1" in
        "${BOOT_A_LABEL}"|"${ROOT_A_LABEL}") echo "a" ;;
        "${BOOT_B_LABEL}"|"${ROOT_B_LABEL}") echo "b" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_by_root_partlabel() {
    case "$1" in
        rootfs_a) echo "a" ;;
        rootfs_b) echo "b" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_partlabel_by_fslabel() {
    case "$1" in
        "${BOOT_A_LABEL}") ab_get_slot_boot_partlabel a ;;
        "${BOOT_B_LABEL}") ab_get_slot_boot_partlabel b ;;
        "${ROOT_A_LABEL}") ab_get_slot_root_partlabel a ;;
        "${ROOT_B_LABEL}") ab_get_slot_root_partlabel b ;;
        *) echo "" ;;
    esac
}

ab_resolve_physical_part_dev() {
    local dev="$1" pkname

    [ -n "${dev}" ] || return 1

    case "${dev}" in
        /dev/mapper/*|/dev/dm-*)
            pkname="$(lsblk -no PKNAME "${dev}" 2>/dev/null | head -n1)"
            if [ -n "${pkname}" ]; then
                echo "/dev/${pkname}"
                return 0
            fi
            ;;
    esac

    echo "${dev}"
}

ab_get_part_by_label() {
    local label="$1" dev partlabel

    dev="$(blkid -t LABEL="${label}" -o device 2>/dev/null | head -n1)"
    if [ -n "${dev}" ]; then
        ab_resolve_physical_part_dev "${dev}"
        return 0
    fi

    partlabel="$(ab_get_slot_partlabel_by_fslabel "${label}")"
    if [ -n "${partlabel}" ]; then
        dev="$(blkid -t PARTLABEL="${partlabel}" -o device 2>/dev/null | head -n1)"
        if [ -n "${dev}" ]; then
            ab_resolve_physical_part_dev "${dev}"
            return 0
        fi
    fi

    echo ""
}

ab_get_uuid_by_label() {
    local label="$1" dev uuid

    dev="$(ab_get_part_by_label "${label}")"
    if [ -n "${dev}" ]; then
        uuid="$(blkid -s UUID -o value "${dev}" 2>/dev/null | head -n1)"
        if [ -n "${uuid}" ]; then
            echo "${uuid}"
            return 0
        fi
    fi

    blkid -t LABEL="${label}" -o value -s UUID 2>/dev/null | head -n1
}
