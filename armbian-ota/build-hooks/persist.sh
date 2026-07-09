#
# Persist Helpers And Hook
#

function ota_configure_persist_fstab() {
    local root_dir="$1"
    local fstab="${root_dir}/etc/fstab"

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
/userdata/.persist/home                /home           none  bind,nofail  0  0
# END armbian-ota persist
EOF

    display_alert "OTA persist" "Configured /userdata/.persist/home bind mount in fstab (recovery mode)" "info"
}

# Seed <persist>/home from the rootfs /home.
# Idempotent: copies only when the persist home is empty, so data already
# preserved on the persist target (partition or directory) always wins.

function ota_seed_persist_dir() {
    local root_dir="$1"
    local persist="$2"

    mkdir -p "${persist}/home"

    if [[ -d "${root_dir}/home" && -z "$(find "${persist}/home" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
        cp -a "${root_dir}/home/." "${persist}/home/" 2>/dev/null || \
            display_alert "OTA persist" "Failed to initialize /home persist data" "warn"
    fi

    chmod 755 "${persist}" "${persist}/home" 2>/dev/null || true
}

function ota_init_userdata_persist() {
    local root_dir="$1"

    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        display_alert "OTA persist" "Skip /userdata/.persist initialization in A/B overlayroot mode" "info"
        return 0
    fi

    # Recovery mode (encrypted or not): no armbi_usrdata partition. Seed
    # /userdata/.persist as a plain directory on the rootfs so the fstab bind
    # mounts have valid sources on first boot. Across OTA it is preserved by
    # /etc/armbian-ota/preserve-list.txt (see ota_preserve_backup_archive).
    ota_seed_persist_dir "${root_dir}" "${root_dir}/userdata/.persist"
    display_alert "OTA persist" "Seeded /userdata/.persist directory (recovery OTA)" "info"
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

function pre_umount_final_image__899_install_fw_env_tool() {
    if [[ "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    display_alert "A/B partition OTA" "Installing fw_env tools into rootfs" "info"
    local root_dir="${MOUNT}"
    local fw_printenv="${root_dir}/usr/bin/fw_printenv"
    local fw_setenv="${root_dir}/usr/bin/fw_setenv"
    local fw_env_config="${root_dir}/etc/fw_env.config"
    local fw_env_device="${AB_FW_ENV_DEVICE:-/dev/mmcblk1}"
    local fw_env_offset="${AB_FW_ENV_OFFSET:-0x3f8000}"
    local fw_env_size="${AB_FW_ENV_SIZE:-0x8000}"

    if [[ ! -x "${fw_printenv}" || ! -x "${fw_setenv}" ]]; then
        display_alert "A/B partition OTA" "fw_printenv/fw_setenv missing in rootfs; install libubootenv-tool" "err"
        return 1
    fi

    mkdir -p "${root_dir}/etc"
    echo "${fw_env_device} ${fw_env_offset} ${fw_env_size}" > "${fw_env_config}" || {
        display_alert "A/B partition OTA" "Failed to create fw_env.config" "err"
        return 1
    }
    display_alert "A/B partition OTA" "Installed fw_env.config: ${fw_env_device} ${fw_env_offset} ${fw_env_size}" "info"

    return 0
}

#
