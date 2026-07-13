#
# Persist Helpers And Hook
#

function ota_configure_persist_fstab() {
    local root_dir="$1"
    local fstab="${root_dir}/etc/fstab"
    local persist_map="${OTA_SUPPORT_DIR}/runtime/policy/persist-map.txt"
    local raw line persist_src mount_target

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
        while IFS= read -r raw || [[ -n "${raw}" ]]; do
            line="$(echo "${raw}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [[ -n "${line}" && "${line}" != \#* ]] || continue
            persist_src="${line%%[[:space:]]*}"
            mount_target="${line#${persist_src}}"
            mount_target="$(echo "${mount_target}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            mount_target="${mount_target%%[[:space:]]*}"
            [[ "${persist_src}" == /* && "${mount_target}" == /* ]] || continue
            mkdir -p "${root_dir}${persist_src}" "${root_dir}${mount_target}"
            printf '%-40s %-15s none  bind,nofail  0  0\n' "${persist_src}" "${mount_target}" >> "${fstab}"
        done < "${persist_map}"
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

function ota_init_userdata_persist() {
    local root_dir="$1"
    local persist_map="${OTA_SUPPORT_DIR}/runtime/policy/persist-map.txt"
    local raw line persist_src mount_target

    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        display_alert "OTA persist" "Skip /userdata/.persist initialization in A/B overlayroot mode" "info"
        return 0
    fi

    # Recovery mode (encrypted or not): no armbi_usrdata partition. Seed
    # /userdata/.persist as a plain directory on the rootfs so the fstab bind
    # mounts have valid sources on first boot. Across OTA it is preserved by
    # /etc/armbian-ota/preserve-list.txt (see ota_preserve_backup_archive).
    if [[ -f "${persist_map}" ]]; then
        while IFS= read -r raw || [[ -n "${raw}" ]]; do
            line="$(echo "${raw}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [[ -n "${line}" && "${line}" != \#* ]] || continue
            persist_src="${line%%[[:space:]]*}"
            mount_target="${line#${persist_src}}"
            mount_target="$(echo "${mount_target}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            mount_target="${mount_target%%[[:space:]]*}"
            [[ "${persist_src}" == /* && "${mount_target}" == /* ]] || continue
            ota_seed_persist_path "${root_dir}" "${persist_src}" "${mount_target}"
        done < "${persist_map}"
    else
        ota_seed_persist_path "${root_dir}" "/userdata/.persist/home" "/home"
    fi
    display_alert "OTA persist" "Seeded persist directories (recovery OTA)" "info"
}

function pre_umount_final_image__897_configure_ota_persist() {
    if [[ "${OTA_ENABLE}" != "yes" ]]; then
        return 0
    fi

    local root_dir="${MOUNT}"
    ota_configure_persist_fstab "${root_dir}"
    ota_init_userdata_persist "${root_dir}"
}

#
# A/B Rootfs Configuration Hooks
#

# 扩容userdata分区
# sudo apt-get install overlayroot
# sudo apt install busybox-static
# /etc/initramfs-tools/initramfs.conf ---> BUSYBOX=y
# /etc/overlayroot.conf ---> overlayroot="device:dev=LABEL=armbi_usrdata"
function pre_umount_final_image__898_config_overlayroot() {
    if [[ "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    display_alert "overlayroot" "Configuring overlayroot for A/B partition OTA" "info"
    local root_dir="${MOUNT}"

    # Modify BUSYBOX from auto to y in initramfs.conf
    if [[ -f "${root_dir}/etc/initramfs-tools/initramfs.conf" ]]; then
        sed -i 's/^BUSYBOX=.*/BUSYBOX=y/' "${root_dir}/etc/initramfs-tools/initramfs.conf"
        display_alert "overlayroot" "Set BUSYBOX=y in initramfs.conf" "info"
    else
        display_alert "overlayroot" "initramfs.conf not found" "warn"
    fi

    # Modify overlayroot in /etc/overlayroot.conf
    if [[ -f "${root_dir}/etc/overlayroot.conf" ]]; then
        sed -i 's/^overlayroot=.*/overlayroot="device:dev=LABEL=armbi_usrdata"/' "${root_dir}/etc/overlayroot.conf"
        display_alert "overlayroot" "Set overlayroot in /etc/overlayroot.conf" "info"
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
