# A/B U-Boot environment helpers.

AB_PARTITIONS_LIB="${OTA_RUNTIME_DIR}/ab/partitions.sh"
[ -r "${AB_PARTITIONS_LIB}" ] || {
    echo "ERROR: A/B partition helper not found: ${AB_PARTITIONS_LIB}" >&2
    return 1
}
. "${AB_PARTITIONS_LIB}"

ab_env_get() {
    fw_printenv -n "$1" 2>/dev/null || true
}

ab_env_set() {
    local env_file entry key value

    env_file="$(mktemp)" || return 1
    for entry in "$@"; do
        key="${entry%%=*}"
        value="${entry#*=}"
        if [ -z "${key}" ] || [ "${key}" = "${entry}" ]; then
            rm -f "${env_file}"
            return 1
        fi
        printf '%s=%s\n' "${key}" "${value}" >> "${env_file}"
    done

    if ! fw_setenv -s "${env_file}"; then
        rm -f "${env_file}"
        return 1
    fi
    rm -f "${env_file}"

    for entry in "$@"; do
        key="${entry%%=*}"
        value="${entry#*=}"
        [ "$(ab_env_get "${key}")" = "${value}" ] || return 1
    done
}

ab_env_retry_max() {
    local retry_max

    retry_max="$(ab_env_get slot_retry_max)"
    echo "${retry_max:-3}"
}

ab_env_current_slot() {
    local current_slot root_dev root_part root_partlabel root_uuid root_a_uuid root_b_uuid

    root_dev="$(findmnt -n -o SOURCE /media/root-ro 2>/dev/null || true)"
    [ -n "${root_dev}" ] || root_dev="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [ -n "${root_dev}" ] || root_dev="$(df / | awk 'NR==2 {print $1}')"
    [ -n "${root_dev}" ] || return 1

    root_part="$(ab_resolve_physical_part_dev "${root_dev}" || true)"
    root_partlabel="$(blkid -s PARTLABEL -o value "${root_part}" 2>/dev/null || true)"
    current_slot="$(ab_get_slot_by_root_partlabel "${root_partlabel}" || true)"
    if [ -n "${current_slot}" ]; then
        echo "${current_slot}"
        return 0
    fi

    root_uuid="$(blkid -o value -s UUID "${root_dev}" 2>/dev/null || true)"
    root_a_uuid="$(ab_get_uuid_by_label "${ROOT_A_LABEL}")"
    root_b_uuid="$(ab_get_uuid_by_label "${ROOT_B_LABEL}")"

    if [ -n "${root_uuid}" ] && [ "${root_uuid}" = "${root_a_uuid}" ]; then
        echo "a"
        return 0
    fi
    if [ -n "${root_uuid}" ] && [ "${root_uuid}" = "${root_b_uuid}" ]; then
        echo "b"
        return 0
    fi

    return 1
}

# U-Boot environment validation.
ab_env_slot_boot_ready() {
    local bootcmd scan preboot devtype devnum part_a part_b boot_mode fit_selector
    bootcmd="$(ab_env_get bootcmd)"
    scan="$(ab_env_get scan_dev_for_boot_part)"
    preboot="$(ab_env_get ab_preboot)"
    devtype="$(ab_env_get ab_boot_devtype)"
    devnum="$(ab_env_get ab_boot_devnum)"
    part_a="$(ab_env_get distro_bootpart_a)"
    part_b="$(ab_env_get distro_bootpart_b)"
    boot_mode="$(ab_env_get ab_boot_mode)"
    fit_selector="$(ab_env_get ab_select_fit_slot)"

    [[ -n "${devtype}" && -n "${devnum}" &&
        -n "${part_a}" && -n "${part_b}" &&
        "${preboot}" == *slot_retry_left* &&
        "${preboot}" == *ota_in_progress* ]] || return 1

    if [[ "${boot_mode}" == "raw-fit" ]]; then
        [[ "${fit_selector}" == *boot_fit_part* &&
            "${bootcmd}" == *"run ab_select_fit_slot"* &&
            "${bootcmd}" == *boot_fit* ]]
        return
    fi

    [[ "${scan}" == *ab_boot_devtype* &&
        "${scan}" == *boot_slot* &&
        "${bootcmd}" == *"run ab_preboot"* &&
        "${bootcmd}" == *"run distro_bootcmd"* ]]
}

ab_env_prepare() {
    local slot="$1"
    local retry_max

    case "${slot}" in
        a|b) ;;
        *) return 1 ;;
    esac
    retry_max="$(ab_env_retry_max)"
    ab_env_set "ota_in_progress=1" "boot_slot=${slot}" "try_count=0" \
        "slot_retry_max=${retry_max}" "slot_retry_left=${retry_max}"
}

ab_env_mark_success() {
    local slot="${1:-}"
    local retry_max

    [ -n "${slot}" ] || slot="$(ab_env_current_slot 2>/dev/null || true)"
    case "${slot}" in
        a|b) ;;
        *) return 1 ;;
    esac
    retry_max="$(ab_env_retry_max)"
    ab_env_set "boot_success=${slot}" "ota_in_progress=0" "try_count=0" \
        "slot_retry_left=${retry_max}"
}

ab_env_rollback() {
    local slot
    local retry_max

    slot="$(ab_env_get boot_success)"
    case "${slot}" in
        a|b) ;;
        *) return 1 ;;
    esac
    retry_max="$(ab_env_retry_max)"
    ab_env_set "boot_slot=${slot}" "ota_in_progress=0" "try_count=0" \
        "slot_retry_left=${retry_max}"
}
