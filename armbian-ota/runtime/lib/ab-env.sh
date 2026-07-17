# A/B U-Boot environment helpers.

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
    case "${retry_max}" in
        ''|*[!0-9]*) echo 3 ;;
        *) echo "${retry_max}" ;;
    esac
}

ab_env_current_slot() {
    local root part label

    root="$(findmnt -n -o SOURCE /media/root-ro 2>/dev/null || true)"
    [ -n "${root}" ] || root="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    part="$(lsblk -no PKNAME "${root}" 2>/dev/null | head -n1 || true)"
    [ -n "${part}" ] && root="/dev/${part}"
    label="$(blkid -s PARTLABEL -o value "${root}" 2>/dev/null || true)"
    case "${label}" in
        rootfs_a) echo a ;;
        rootfs_b) echo b ;;
        *) return 1 ;;
    esac
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
