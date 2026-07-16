# Persist Helpers

function ota_persist_is_safe_absolute_path() {
    local path="$1"

    case "${path}" in
        /*) ;;
        *) return 1 ;;
    esac

    case "${path}" in
        "/"|"/."|"/.."|*"../"*|*"/.."|*"*"*|*"?"*|*"["*|*"]"*) return 1 ;;
    esac

    return 0
}

function ota_for_each_persist_mapping() {
    local persist_map="$1"
    local handler="$2"
    local raw line persist_src mount_target
    shift 2

    while IFS= read -r raw || [[ -n "${raw}" ]]; do
        line="$(echo "${raw}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -n "${line}" && "${line}" != \#* ]] || continue
        persist_src="${line%%[[:space:]]*}"
        mount_target="${line#${persist_src}}"
        mount_target="$(echo "${mount_target}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        mount_target="${mount_target%%[[:space:]]*}"
        if ! ota_persist_is_safe_absolute_path "${persist_src}" || \
            ! ota_persist_is_safe_absolute_path "${mount_target}"; then
            display_alert "OTA persist" "Skip unsafe persist mapping: ${line}" "warn"
            continue
        fi

        "${handler}" "$@" "${persist_src}" "${mount_target}"
    done < "${persist_map}"
}

function ota_set_config_option() {
    local config_file="$1"
    local key="$2"
    local assignment="$3"

    if grep -q "^${key}=" "${config_file}"; then
        sed -i "s|^${key}=.*|${assignment}|" "${config_file}"
    else
        printf '%s\n' "${assignment}" >> "${config_file}"
    fi
}

function ota_append_persist_fstab_entry() {
    local root_dir="$1"
    local fstab="$2"
    local persist_src="$3"
    local mount_target="$4"

    mkdir -p "${root_dir}${persist_src}" "${root_dir}${mount_target}"
    printf '%-40s %-15s none  bind,nofail  0  0\n' "${persist_src}" "${mount_target}" >> "${fstab}"
}

function ota_configure_persist_fstab() {
    local root_dir="$1"
    local fstab="${root_dir}/etc/fstab"
    local persist_map="${OTA_RUNTIME_SRC}/policy/persist-map.txt"

    [[ -f "${fstab}" ]] || {
        display_alert "OTA persist" "fstab not found, skip persist bind mounts" "warn"
        return 0
    }

    mkdir -p "${root_dir}/userdata" "${root_dir}/home"

    sed -i '/^# BEGIN armbian-ota persist$/,/^# END armbian-ota persist$/d' "${fstab}"

    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        display_alert "OTA persist" "Skip /home bind mount; A/B overlayroot persists rootfs writes on armbi_usrdata" "info"
        return 0
    fi

    # Recovery OTA -- encrypted or not -- is a single rootfs partition with no
    # armbi_usrdata. /userdata is a plain directory on the rootfs, so do not add
    # LABEL=armbi_usrdata or userdata.mount ordering here.
    cat >> "${fstab}" <<EOF

# BEGIN armbian-ota persist
# recovery OTA: /userdata is a rootfs directory preserved by /etc/armbian-ota/preserve-list.txt
EOF

    if [[ -f "${persist_map}" ]]; then
        ota_for_each_persist_mapping "${persist_map}" ota_append_persist_fstab_entry \
            "${root_dir}" "${fstab}"
    else
        mkdir -p "${root_dir}/userdata/.persist/home" "${root_dir}/home"
        printf '%-40s %-15s none  bind,nofail  0  0\n' "/userdata/.persist/home" "/home" >> "${fstab}"
    fi

    cat >> "${fstab}" <<EOF
# END armbian-ota persist
EOF

    display_alert "OTA persist" "Configured persist bind mounts in fstab (recovery mode)" "info"
}

# Seed persist sources from their target paths.
# Idempotent: copies only when the persist source is empty, so data already
# preserved on the persist target (partition or directory) always wins.

function ota_seed_persist_path() {
    local root_dir="$1"
    local persist_src="$2"
    local mount_target="$3"
    local persist="${root_dir}${persist_src}"
    local target="${root_dir}${mount_target}"

    mkdir -p "${persist}"

    if [[ -d "${target}" && -z "$(find "${persist}" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
        cp -a "${target}/." "${persist}/" 2>/dev/null || \
            display_alert "OTA persist" "Failed to initialize ${mount_target} persist data" "warn"
    fi

    chmod 755 "${persist}" 2>/dev/null || true
}

function ota_seed_persist_mapping() {
    local root_dir="$1"
    local persist_src="$2"
    local mount_target="$3"

    ota_seed_persist_path "${root_dir}" "${persist_src}" "${mount_target}"
}

function ota_init_userdata_persist() {
    local root_dir="$1"
    local persist_map="${OTA_RUNTIME_SRC}/policy/persist-map.txt"

    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        display_alert "OTA persist" "Skip /userdata/.persist initialization in A/B overlayroot mode" "info"
        return 0
    fi

    # Recovery mode (encrypted or not): no armbi_usrdata partition. Seed
    # /userdata/.persist as a plain directory on the rootfs so the fstab bind
    # mounts have valid sources on first boot. Across OTA it is preserved by
    # /etc/armbian-ota/preserve-list.txt (see ota_preserve_backup_archive).
    if [[ -f "${persist_map}" ]]; then
        ota_for_each_persist_mapping "${persist_map}" ota_seed_persist_mapping "${root_dir}"
    else
        ota_seed_persist_path "${root_dir}" "/userdata/.persist/home" "/home"
    fi
    display_alert "OTA persist" "Seeded persist directories (recovery OTA)" "info"
}

# Build Hooks (execution order)

function pre_umount_final_image__897_configure_ota_persist() {
    if [[ "${OTA_ENABLE}" != "yes" ]]; then
        return 0
    fi

    local root_dir="${MOUNT}"
    ota_configure_persist_fstab "${root_dir}"
    ota_init_userdata_persist "${root_dir}"
}

# Configure overlayroot before Armbian rebuilds the final initramfs.
function pre_update_initramfs__893_config_overlayroot() {
    if [[ "${OTA_ENABLE}" != "yes" || "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    display_alert "overlayroot" "Configuring overlayroot for A/B partition OTA" "info"
    local root_dir="${MOUNT}"

    if [[ -f "${root_dir}/etc/initramfs-tools/initramfs.conf" ]]; then
        if ota_set_config_option "${root_dir}/etc/initramfs-tools/initramfs.conf" "BUSYBOX" "BUSYBOX=y"; then
            display_alert "overlayroot" "Set BUSYBOX=y in initramfs.conf" "info"
        else
            display_alert "overlayroot" "Failed to set BUSYBOX=y in initramfs.conf" "warn"
        fi
    else
        display_alert "overlayroot" "initramfs.conf not found" "warn"
    fi

    if [[ -f "${root_dir}/etc/overlayroot.conf" ]]; then
        if ota_set_config_option "${root_dir}/etc/overlayroot.conf" "overlayroot" \
            'overlayroot="device:dev=LABEL=armbi_usrdata"'; then
            display_alert "overlayroot" "Set overlayroot in /etc/overlayroot.conf" "info"
        else
            display_alert "overlayroot" "Failed to set overlayroot in /etc/overlayroot.conf" "warn"
        fi
    else
        display_alert "overlayroot" "/etc/overlayroot.conf not found" "warn"
    fi

    # The Debian overlayroot package installs a MOTD script that dumps
    # overlay mount entries on every login. It is noisy for production images.
    if [[ -e "${root_dir}/etc/update-motd.d/97-overlayroot" ]]; then
        rm -f "${root_dir}/etc/update-motd.d/97-overlayroot"
        display_alert "overlayroot" "Removed overlayroot MOTD mount dump" "info"
    fi
}
