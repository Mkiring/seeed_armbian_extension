# Recovery OTA rootfs and initramfs installation hooks

readonly OTA_ROOTFS_RUNTIME_DIR="usr/share/armbian-ota"
readonly OTA_COMMON_INITRAMFS="${OTA_SUPPORT_DIR}/common/initramfs"

function ota_install_recovery_runtime_to_rootfs() {
    local root_dir="$1"

    ota_install_common_runtime_to_rootfs "${root_dir}" || return 1
    ota_sync_rootfs "Recovery OTA runtime" "${OTA_RECOVERY_ROOTFS}" "${root_dir}"
}

function ota_install_recovery_initramfs_file() {
    local source="$1" destination="$2" mode="$3"

    [[ -f "${source}" ]] || {
        display_alert "Recovery OTA initramfs" "Missing source file: ${source}" "err"
        return 1
    }
    install -D -m "${mode}" "${source}" "${destination}" || {
        display_alert "Recovery OTA initramfs" "Failed to install: ${source}" "err"
        return 1
    }
}

# Install Seeed OTA *common* initramfs pieces shared by recovery and A/B
# images: the userdata resolver (00-seeed-bind-userdata) plus its hook and
# helper library. Anchoring userdata to the boot disk must happen in both
# modes or root-rw ends up on the wrong disk when multiple disks carry the
# same image.
function ota_install_common_initramfs() {
    local root_dir="$1"
    local title="Seeed OTA common initramfs"
    local -a common_initramfs_file_list=(
        "hooks/98-seeed-bind-userdata:etc/initramfs-tools/hooks/98-seeed-bind-userdata:0755"
        "scripts/init-bottom/00-seeed-bind-userdata:etc/initramfs-tools/scripts/init-bottom/00-seeed-bind-userdata:0755"
        "scripts/init-bottom/zz-seeed-mount-boot:etc/initramfs-tools/scripts/init-bottom/zz-seeed-mount-boot:0755"
    )
    local entry source_path destination_path mode

    display_alert "${title}" "Installing userdata resolver" "info"
    for entry in "${common_initramfs_file_list[@]}"; do
        IFS=: read -r source_path destination_path mode <<< "${entry}"
        ota_install_recovery_initramfs_file \
            "${OTA_COMMON_INITRAMFS}/${source_path}" \
            "${root_dir}/${destination_path}" "${mode}" || return 1
    done
}

function ota_install_recovery_initramfs() {
    local root_dir="$1"
    local title="Recovery OTA initramfs"
    local -a initramfs_file_list=(
        "hooks/99-copy-tools:etc/initramfs-tools/hooks/99-copy-tools:0755"
        "scripts/init-premount/99-ota-apply:etc/initramfs-tools/scripts/init-premount/99-ota-apply:0755"
        "recovery/log.sh:etc/initramfs-tools/ota/recovery/log.sh:0644"
        "recovery/device.sh:etc/initramfs-tools/ota/recovery/device.sh:0644"
        "recovery/payload.sh:etc/initramfs-tools/ota/recovery/payload.sh:0644"
    )
    local entry source_path destination_path mode runtime_hash

    display_alert "${title}" "Preparing recovery OTA hooks for initramfs" "info"
    mkdir -p "${root_dir}/etc/initramfs-tools/conf.d"

    ota_install_common_initramfs "${root_dir}" || return 1

    for entry in "${initramfs_file_list[@]}"; do
        IFS=: read -r source_path destination_path mode <<< "${entry}"
        ota_install_recovery_initramfs_file \
            "${OTA_RECOVERY_INITRAMFS}/${source_path}" \
            "${root_dir}/${destination_path}" "${mode}" || return 1
    done

    runtime_hash="$(
        {
            cd "${root_dir}" || exit 1
            sha256sum "${OTA_ROOTFS_RUNTIME_DIR}/state.sh"
            sha256sum "${OTA_ROOTFS_RUNTIME_DIR}/find-userdata.sh"
            for entry in "${initramfs_file_list[@]}"; do
                IFS=: read -r source_path destination_path mode <<< "${entry}"
                sha256sum "${destination_path}"
            done
            sha256sum "etc/initramfs-tools/hooks/98-seeed-bind-userdata"
            sha256sum "etc/initramfs-tools/scripts/init-bottom/00-seeed-bind-userdata"
            sha256sum "etc/initramfs-tools/scripts/init-bottom/zz-seeed-mount-boot"
        } | sha256sum | awk '{print $1}'
    )" || {
        display_alert "${title}" "Failed to calculate initramfs cache stamp" "err"
        return 1
    }

    [[ -n "${runtime_hash}" ]] || {
        display_alert "${title}" "Empty initramfs cache stamp" "err"
        return 1
    }
    printf 'ARMBIAN_OTA_RUNTIME_HASH=%s\n' "${runtime_hash}" >"${root_dir}/etc/initramfs-tools/conf.d/armbian-ota-runtime.hash" || {
        display_alert "${title}" "Failed to write initramfs cache stamp" "err"
        return 1
    }
}

function pre_update_initramfs__894_install_recovery_ota_hooks() {
    ota_install_recovery_runtime_to_rootfs "${MOUNT}" || return 1
    ota_install_recovery_initramfs "${MOUNT}"
}

# Remove the /boot fstab entry: /boot is mounted by the initramfs
# (zz-seeed-mount-boot, anchored to the rootfs disk) instead. A fstab source
# is unworkable in multi-disk clone setups -- a UUID flips between clones
# through udev's duplicate-UUID symlinks, and a hand-made /dev symlink never
# satisfies systemd's udev-backed device unit (observed as a ~90s stall in
# "Expecting device dev-armbian-boot.device" and unbootable eMMC images).
# Raw-FIT (secure boot) layouts never get a /boot entry, so the grep does not
# match there.
function pre_update_initramfs__896_recovery_boot_anchor_fstab() {
    local fstab="${MOUNT}/etc/fstab"

    [[ -f "${fstab}" ]] || return 0
    if grep -qE '^[^[:space:]]+[[:space:]]+/boot([[:space:]]|$)' "${fstab}"; then
        sed -i -E '\@^[^[:space:]]+[[:space:]]+/boot([[:space:]]|$)@d' "${fstab}" ||
            exit_with_error "Recovery OTA" "failed to remove fstab /boot entry"
        display_alert "Recovery OTA" "removed fstab /boot entry (initramfs mounts /boot anchored)" "info"
    fi
}
