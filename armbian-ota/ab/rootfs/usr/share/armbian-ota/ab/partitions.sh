# A/B partition discovery helpers.

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

ab_get_slot_partlabel_by_fslabel() {
    case "$1" in
        armbi_boota) echo "boot_a" ;;
        armbi_bootb) echo "boot_b" ;;
        armbi_roota) echo "rootfs_a" ;;
        armbi_rootb) echo "rootfs_b" ;;
        *) echo "" ;;
    esac
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
