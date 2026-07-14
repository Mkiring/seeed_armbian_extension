# OTA Package Creation Helpers
#

function ota_secure_boot_autodecrypt_enabled() {
    [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]
}

function ota_encrypted_autodecrypt_nonsecure_enabled() {
    [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" && "${RK_SECURE_UBOOT_ENABLE}" != "yes" ]]
}

function ota_require_host_tools() {
    local tool

    for tool in "$@"; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            display_alert "Error: Missing required tool" "${tool}" "err"
            return 1
        fi
    done
}

function ota_write_payload_tools_readme() {
    local payload_tools_dir="$1"

    cat > "${payload_tools_dir}/README_INSTALL.txt" << 'EOF'
Armbian OTA Runtime Tools

This payload contains OTA runtime scripts for fallback/offline installation.

If firmware was built with OTA enabled:
- AB firmware (`AB_PART_OTA=yes`) already includes AB OTA runtime/tools.
- Recovery firmware (`OTA_ENABLE=yes`, no `AB_PART_OTA`) already includes Recovery OTA runtime/tools.

In those cases, you only need to copy the OTA package and run `armbian-ota start <ota-package.tar.gz>`.

Typical usage:
1) If your firmware does not include OTA runtime, copy ota_tools/ to target board.
2) Install runtime CLI and libraries manually (as root), for example:
   cp -a runtime/bin/armbian-ota /usr/sbin/armbian-ota
   chmod +x /usr/sbin/armbian-ota
   mkdir -p /usr/share/armbian-ota
   cp -a runtime/lib/common.sh /usr/share/armbian-ota/common.sh
   cp -a runtime/lib/state.sh /usr/share/armbian-ota/state.sh
   cp -a runtime/lib/persist.sh /usr/share/armbian-ota/persist.sh
   cp -a runtime/lib/preserve.sh /usr/share/armbian-ota/preserve.sh
   mkdir -p /etc/armbian-ota
   if [ -f /etc/armbian-ota/persist-map.txt ]; then
       cp -a runtime/policy/persist-map.txt /etc/armbian-ota/persist-map.txt.default
   else
       cp -a runtime/policy/persist-map.txt /etc/armbian-ota/persist-map.txt
   fi
   if [ -f /etc/armbian-ota/preserve-list.txt ]; then
       cp -a runtime/policy/preserve-list.txt /etc/armbian-ota/preserve-list.txt.default
   else
       cp -a runtime/policy/preserve-list.txt /etc/armbian-ota/preserve-list.txt
   fi
   cp -a ab/backend.sh /usr/share/armbian-ota/backend-ab.sh
   cp -a recovery/backend.sh /usr/share/armbian-ota/backend-recovery.sh
   mkdir -p /usr/share/armbian-ota/recovery
   cp -a recovery/. /usr/share/armbian-ota/recovery/

3) Trigger OTA:
   armbian-ota start <ota-package.tar.gz>
EOF
}

function ota_copy_payload_tools() {
    local ota_temp_dir="$1"
    local ota_ext_dir
    ota_ext_dir="${OTA_SUPPORT_DIR}"
    local runtime_src="${ota_ext_dir}/runtime"
    local ab_src="${ota_ext_dir}/ab"
    local recovery_src="${ota_ext_dir}/recovery"
    local payload_tools_dir="${ota_temp_dir}/ota_tools"

    mkdir -p "${payload_tools_dir}"

    if [[ -d "${runtime_src}" ]]; then
        mkdir -p "${payload_tools_dir}/runtime"
        cp -a "${runtime_src}/." "${payload_tools_dir}/runtime/" || {
            display_alert "OTA payload" "Failed to copy runtime tools into payload" "err"
            return 1
        }
    else
        display_alert "OTA payload" "runtime source dir not found: ${runtime_src}" "warn"
    fi

    if [[ -d "${ab_src}" ]]; then
        mkdir -p "${payload_tools_dir}/ab"
        cp -a "${ab_src}/backend.sh" "${payload_tools_dir}/ab/" 2>/dev/null || true
        cp -a "${ab_src}/lib" "${payload_tools_dir}/ab/" 2>/dev/null || true
        cp -a "${ab_src}/systemd" "${payload_tools_dir}/ab/" 2>/dev/null || true
    fi

    if [[ -d "${recovery_src}" ]]; then
        mkdir -p "${payload_tools_dir}/recovery"
        cp -a "${recovery_src}/backend.sh" "${payload_tools_dir}/recovery/" 2>/dev/null || true
        cp -a "${recovery_src}/initramfs_hooks" "${payload_tools_dir}/recovery/" 2>/dev/null || true
    fi

    ota_write_payload_tools_readme "${payload_tools_dir}"
}

function ota_write_sha256_file() {
    local ota_temp_dir="$1"
    local image_name="$2"
    local sha_file="$3"

    if command -v sha256sum >/dev/null 2>&1; then
        (cd "${ota_temp_dir}" && sha256sum "${image_name}" > "${sha_file}") || {
            display_alert "Warning: Failed to generate SHA256 for ${image_name}" "${sha_file}" "warn"
        }
    else
        display_alert "Warning: sha256sum not available; skipping ${image_name} SHA256" "" "warn"
    fi
}

function ota_verify_sha256_file() {
    local ota_temp_dir="$1"
    local sha_file="$2"
    local image_name="$3"

    [[ -f "${sha_file}" ]] || return 0

    if ! (cd "${ota_temp_dir}" && sha256sum -c "$(basename "${sha_file}")" >/dev/null 2>&1); then
        display_alert "Error: ${image_name} SHA256 verification failed" "${sha_file}" "err"
        return 1
    fi
}

function ota_verify_extracted_archives() {
    local ota_temp_dir="$1"
    local secure_boot_and_decrypt="$2"
    local boot_tar="$3"
    local rootfs_tar="$4"
    local boot_sha_file="$5"
    local rootfs_sha_file="$6"

    if [[ ! -f "${rootfs_tar}" ]]; then
        display_alert "Error: rootfs.tar.gz not found" "" "err"
        return 1
    fi

    if ! tar -tzf "${rootfs_tar}" >/dev/null 2>&1; then
        display_alert "Error: rootfs.tar.gz is corrupted or invalid" "" "err"
        return 1
    fi

    ota_verify_sha256_file "${ota_temp_dir}" "${rootfs_sha_file}" "rootfs.tar.gz" || return 1

    if [[ "${secure_boot_and_decrypt}" == "yes" && -f "${ota_temp_dir}/boot.itb" ]]; then
        if [[ ! -r "${ota_temp_dir}/boot.itb" ]]; then
            display_alert "Error: boot.itb is not readable" "" "err"
            return 1
        fi

        ota_verify_sha256_file "${ota_temp_dir}" "${boot_sha_file}" "boot.itb" || return 1
        display_alert "Archive verification completed" "boot.itb and rootfs.tar.gz are valid" "info"
    elif [[ -f "${boot_tar}" ]]; then
        if ! tar -tzf "${boot_tar}" >/dev/null 2>&1; then
            display_alert "Error: boot.tar.gz is corrupted or invalid" "" "err"
            return 1
        fi

        ota_verify_sha256_file "${ota_temp_dir}" "${boot_sha_file}" "boot.tar.gz" || return 1
        display_alert "Archive verification completed" "boot.tar.gz and rootfs.tar.gz are valid" "info"
    else
        display_alert "Archive verification completed" "rootfs.tar.gz is valid (no boot partition found)" "info"
    fi
}

function ota_extraction_summary() {
    local ota_temp_dir="$1"
    local secure_boot_and_decrypt="$2"
    local boot_tar="$3"

    if [[ "${secure_boot_and_decrypt}" == "yes" && -f "${ota_temp_dir}/boot.itb" ]]; then
        echo "boot.itb + rootfs.tar.gz (secure boot)"
    elif [[ -f "${boot_tar}" ]]; then
        echo "boot.tar.gz + rootfs.tar.gz"
    else
        echo "rootfs.tar.gz only"
    fi
}

function ota_write_package_env() {
    local ota_temp_dir="$1"
    local manifest_mode="$2"
    local ota_mode_file="${ota_temp_dir}/package.env"

    cat > "${ota_mode_file}" << EOF
OTA_MODE=${manifest_mode}
OTA_ENCRYPTED=${CRYPTROOT_ENABLE:-no}
BOARD=${BOARD}
RELEASE=${RELEASE}
BRANCH=${BRANCH}
VERSION=${IMAGE_VERSION:-"${REVISION}"}
KERNEL=${KERNEL_VERSION:-"${IMAGE_INSTALLED_KERNEL_VERSION}"}
EOF
}

function ota_write_ab_version_file() {
    local ota_temp_dir="$1"
    local version_file="${ota_temp_dir}/version.txt"

    [[ "${AB_PART_OTA}" == "yes" ]] || return 0

    cat > "${version_file}" << EOF
# Armbian AB OTA Package Version Info
# Generated: $(date)

VERSION=${IMAGE_VERSION:-"${REVISION}"}
VENDOR=${VENDOR}
BOARD=${BOARD}
RELEASE=${RELEASE}
BRANCH=${BRANCH}
KERNEL=${KERNEL_VERSION:-"${IMAGE_INSTALLED_KERNEL_VERSION}"}
EOF
    display_alert "AB partition OTA" "Created version.txt for OTA package" "info"
}

function ota_write_manifest() {
    local ota_temp_dir="$1"
    local base_image_name="$2"
    local secure_boot_and_decrypt="$3"
    local boot_tar="$4"
    local rootfs_tar="$5"
    local manifest_file="${ota_temp_dir}/manifest.txt"

    cat > "${manifest_file}" << EOF
# Armbian OTA Package Manifest
# Generated on: $(date)
# Original image: ${base_image_name}

Package Contents:
EOF

    if [[ "${secure_boot_and_decrypt}" == "yes" && -f "${ota_temp_dir}/boot.itb" ]]; then
        echo "- boot.itb: FIT boot image for secure boot" >> "${manifest_file}"
    elif [[ -f "${boot_tar}" ]]; then
        echo "- boot.tar.gz: Boot partition image" >> "${manifest_file}"
    fi
    if [[ -f "${rootfs_tar}" ]]; then
        echo "- rootfs.tar.gz: Root filesystem image" >> "${manifest_file}"
    fi
    if [[ "${AB_PART_OTA}" == "yes" && -f "${ota_temp_dir}/version.txt" ]]; then
        echo "- version.txt: Version information" >> "${manifest_file}"
    fi
    echo "- package.env: OTA runtime metadata" >> "${manifest_file}"
    echo "- ota_tools/: OTA runtime scripts and helpers" >> "${manifest_file}"
}

function ota_create_final_tarball() {
    local ota_temp_dir="$1"
    local ota_output_path="$2"

    (
        cd "${ota_temp_dir}" &&
        {
            printf '%s\0' "package.env"
            find . -mindepth 1 ! -path "./package.env" ! -type d -printf '%P\0' | LC_ALL=C sort -z
        } | tar --null -czf "${ota_output_path}" -T -
    )
}

function ota_write_package_checksums() {
    local ota_output_path="$1"
    local checksum_file="$2"
    local ota_package_name="$3"
    local ota_md5 ota_sha256

    ota_md5="$(md5sum "${ota_output_path}" | awk '{print $1}')"
    ota_sha256="$(sha256sum "${ota_output_path}" | awk '{print $1}')"

    cat > "${checksum_file}" << EOF
# Armbian OTA Package Checksums
# Package: ${ota_package_name}
# Generated: $(date)

MD5:    ${ota_md5}
SHA256: ${ota_sha256}
EOF
}

#
# OTA Package Creation Hook
#

function pre_umount_final_image__901_create_ota_payload_pkg() {

    display_alert "pre_umount_final_image__901 Extracting partition images from loop device" "Detecting and extracting partitions from ${LOOP}" "info"

    # Check for secure boot and auto ota configuration
    local secure_boot_and_decrypt="no"
    local encrypted_autodecrypt_nonsecure="no"
    if ota_secure_boot_autodecrypt_enabled; then
        secure_boot_and_decrypt="yes"
        display_alert "Secure boot and auto ota enabled" "Using FIT image workflow" "info"
    elif ota_encrypted_autodecrypt_nonsecure_enabled; then
        encrypted_autodecrypt_nonsecure="yes"
        display_alert "Encrypted auto-decrypt OTA" "Non-secure boot mode: use mapper rootfs and package plain boot partition" "info"
    fi

    # Create temporary directory for OTA package building
    local ota_temp_dir="${WORKDIR}/ota_package_build_$$"
    mkdir -p "$ota_temp_dir"

    # Check if loop device exists
    if [[ ! -b "${LOOP}" ]]; then
        display_alert "Error: Loop device not found" "${LOOP}" "err"
        return 1
    fi

    ota_require_host_tools tar mount || return 1

    # For secure boot and auto ota, we don't need to detect partitions
    local boot_partition=""
    local rootfs_partition=""

    if [[ "$secure_boot_and_decrypt" == "yes" ]]; then
        display_alert "Secure boot mode" "Skipping partition detection" "info"
        # In secure boot mode, we'll use /dev/mapper/armbian-root directly
        rootfs_partition="encrypted"
    elif [[ "${AB_PART_OTA}" == "yes" ]]; then
        # AB partition OTA mode: Detect boot_a and rootfs_a partitions
        display_alert "AB partition OTA mode" "Detecting A-slot partitions" "info"

        display_alert "AB partition OTA" "Looking for armbi_boota and armbi_roota partitions" "info"

        # For AB OTA, we use fixed partition indices from the build process
        if [[ -n "${AB_BOOT_A_PART_INDEX}" ]]; then
            boot_partition="${LOOP}p${AB_BOOT_A_PART_INDEX}"
            display_alert "AB partition OTA" "Using boot_a partition: ${boot_partition}" "info"
        fi

        if [[ -n "${AB_ROOTFS_A_PART_INDEX}" ]]; then
            rootfs_partition="${LOOP}p${AB_ROOTFS_A_PART_INDEX}"
            display_alert "AB partition OTA" "Using rootfs_a partition: ${rootfs_partition}" "info"
        fi

        # Ensure rootfs partition exists
        if [[ -z "$rootfs_partition" || ! -b "$rootfs_partition" ]]; then
            display_alert "Error: Could not find rootfs_a partition" "${rootfs_partition:-not set}" "err"
            return 1
        fi
    else
        # Normal mode: Dynamically detect boot and rootfs partitions
        # Get all partition information (including size, mount point)
        local partition_info
        partition_info=$(lsblk -ln -o NAME,SIZE,MOUNTPOINT "${LOOP}" | grep -E "${LOOP##*/}p?[0-9]+" | sort)

        # Print partition_info for debugging
        display_alert "Loop device partitions" "${LOOP}" "info"
        display_alert "DEBUG: partition_info content" "=== START ===" "info"
        echo "$partition_info" | while IFS= read -r line; do
            display_alert "DEBUG partition_info line" "[$line]" "info"
        done
        display_alert "DEBUG: partition_info content" "=== END ===" "info"

        if [[ -z "$partition_info" ]]; then
            display_alert "Error: No partitions found on loop device" "${LOOP}" "err"
            return 1
        fi

        # Iterate through partitions, using mount point detection strategy
        while IFS= read -r partition_line; do
            if [[ -n "$partition_line" ]]; then
                display_alert "DEBUG raw line" "[$partition_line]" "debug"

                # Get clearer information: NAME, SIZE, MOUNTPOINT
                local partition_name=$(echo "$partition_line" | awk '{print $1}')
                local part_size=$(echo "$partition_line" | awk '{print $2}')
                local mount_point=$(echo "$partition_line" | awk '{print $3}')

                local full_path="/dev/$partition_name"

                display_alert "DEBUG parsed fields" "name=${partition_name}, size=${part_size}, mount=${mount_point}" "debug"

                if [[ -b "$full_path" ]]; then
                    # Use mount point information to differentiate
                    if [[ -n "$mount_point" ]]; then
                        # Detect boot partition: mount path contains "/boot"
                        if [[ "$mount_point" == *"/boot" && -z "$boot_partition" ]]; then
                            boot_partition="$full_path"
                            display_alert "Detected boot partition by mount point" "${full_path} (mounted at ${mount_point})" "info"
                            continue
                        fi

                        # Detect rootfs partition: mounted at root directory (does not end with "/boot")
                        if [[ "$mount_point" != *"/boot" && -z "$rootfs_partition" ]]; then
                            rootfs_partition="$full_path"
                            display_alert "Detected rootfs partition by mount point" "${full_path} (mounted at ${mount_point})" "info"
                            continue
                        fi
                    fi
                fi
            fi
        done <<< "$partition_info"

        # Ensure at least rootfs partition exists (except encrypted auto-decrypt non-secure mode)
        if [[ -z "$rootfs_partition" ]]; then
            if [[ "${encrypted_autodecrypt_nonsecure}" == "yes" ]]; then
                display_alert "Encrypted auto-decrypt OTA" "Skip rootfs partition detection in non-secure mode, rootfs will use /dev/mapper/armbian-root" "info"
            else
                display_alert "Error: Could not identify rootfs partition" "" "err"
                return 1
            fi
        fi
    fi

    # Fallback: try boot partition by LABEL/PARTLABEL when mountpoint probing misses it.
    if [[ -z "${boot_partition}" ]]; then
        local boot_candidate=""
        for boot_label in armbi_boot boot; do
            boot_candidate="$(blkid -t LABEL="${boot_label}" -o device 2>/dev/null | head -n1)"
            if [[ -n "${boot_candidate}" && -b "${boot_candidate}" ]]; then
                boot_partition="${boot_candidate}"
                display_alert "Boot partition fallback" "Detected boot partition by LABEL=${boot_label}: ${boot_partition}" "info"
                break
            fi
        done

        if [[ -z "${boot_partition}" ]]; then
            boot_candidate="$(blkid -t PARTLABEL=boot -o device 2>/dev/null | head -n1)"
            if [[ -n "${boot_candidate}" && -b "${boot_candidate}" ]]; then
                boot_partition="${boot_candidate}"
                display_alert "Boot partition fallback" "Detected boot partition by PARTLABEL=boot: ${boot_partition}" "info"
            fi
        fi
    fi

    # Get partition information
    local boot_size=0
    local rootfs_size=0

    if [[ "$secure_boot_and_decrypt" != "yes" && "${encrypted_autodecrypt_nonsecure}" != "yes" ]]; then
        rootfs_size=$(blockdev --getsize64 "$rootfs_partition" 2>/dev/null || echo "0")
        if [[ -n "$boot_partition" ]]; then
            boot_size=$(blockdev --getsize64 "$boot_partition" 2>/dev/null || echo "0")
        fi
        display_alert "Found partitions" "boot: ${boot_partition:-"none"} (${boot_size} bytes), rootfs: ${rootfs_partition} (${rootfs_size} bytes)" "info"
    else
        if [[ "$secure_boot_and_decrypt" == "yes" ]]; then
            display_alert "Secure boot mode active" "Using boot.itb and encrypted rootfs" "info"
        else
            if [[ -n "$boot_partition" ]]; then
                boot_size=$(blockdev --getsize64 "$boot_partition" 2>/dev/null || echo "0")
            fi
            display_alert "Encrypted auto-decrypt mode active" "Using mapper rootfs and boot partition ${boot_partition:-none} (${boot_size} bytes)" "info"
        fi
    fi

    # Create temporary mount points
    local boot_mount="${WORKDIR}/boot_mount"
    local rootfs_mount="${WORKDIR}/rootfs_mount"
    mkdir -p "$boot_mount" "$rootfs_mount"

    # Define tar package paths
    local boot_tar="${ota_temp_dir}/boot.tar.gz"
    local rootfs_tar="${ota_temp_dir}/rootfs.tar.gz"

    # SHA256 checksum files to be included in final OTA tarball
    local boot_sha_file="${ota_temp_dir}/boot.sha256"
    local rootfs_sha_file="${ota_temp_dir}/rootfs.sha256"

    # Handle boot partition content
    if [[ "$secure_boot_and_decrypt" == "yes" ]]; then
        local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
        # For secure boot with auto ota, look for boot.itb in the chroot
        local boot_itb_source="${uboot_src}/fit/boot.itb"
        if [[ -f "$boot_itb_source" ]]; then
            display_alert "Copying FIT boot image" "${boot_itb_source} -> boot.itb" "info"
            if cp "$boot_itb_source" "${ota_temp_dir}/boot.itb"; then
                local boot_itb_size=$(stat -c%s "${ota_temp_dir}/boot.itb")
                display_alert "FIT boot image copied" "boot.itb size: $((boot_itb_size / 1024)) KB" "info"

                ota_write_sha256_file "${ota_temp_dir}" "boot.itb" "${boot_sha_file}"
            else
                display_alert "Warning: Failed to copy boot.itb" "" "warn"
            fi
        else
            display_alert "Warning: boot.itb not found at ${boot_itb_source}" "" "warn"
        fi
    elif [[ -n "$boot_partition" && -b "$boot_partition" ]]; then
        # Normal boot partition extraction
        display_alert "Extracting boot partition content" "${boot_partition} -> boot.tar.gz" "info"
        if mount "$boot_partition" "$boot_mount"; then
            # Create boot.tar.gz
            if (cd "$boot_mount" && tar -czf "$boot_tar" .); then
                local boot_tar_size=$(stat -c%s "$boot_tar")
                display_alert "Boot content archived" "boot.tar.gz size: $((boot_tar_size / 1024)) KB" "info"
                display_alert "Boot partition contents" "Found $(find "$boot_mount" -type f | wc -l) files" "debug"
                ota_write_sha256_file "${ota_temp_dir}" "boot.tar.gz" "${boot_sha_file}"
            else
                umount "$boot_mount" 2>/dev/null || true
                display_alert "Warning: Failed to create boot.tar.gz" "" "warn"
            fi
            umount "$boot_mount" 2>/dev/null || true
        else
            display_alert "Warning: Failed to mount boot partition" "${boot_partition}" "warn"
        fi
    fi

    # Extract rootfs partition content
    local rootfs_source=""

    if [[ "$secure_boot_and_decrypt" == "yes" || "${RK_AUTO_DECRYP}" == "yes" ]]; then
        # For encrypted rootfs, we need to use the mapper device
        rootfs_source="/dev/mapper/armbian-root"
        display_alert "Encrypted rootfs detected" "Using mapper device: ${rootfs_source}" "info"

        # Ensure the encrypted partition is set up
        if [[ ! -e "$rootfs_source" ]]; then
            display_alert "Error: Encrypted mapper device not found" "${rootfs_source}" "err"
            rm -rf "$ota_temp_dir"
            return 1
        fi
    else
        # Normal rootfs partition
        rootfs_source="$rootfs_partition"
    fi

    display_alert "Extracting rootfs partition content" "${rootfs_source} -> rootfs.tar.gz" "info"
    if mount "$rootfs_source" "$rootfs_mount"; then
        # Create rootfs.tar.gz
        if (cd "$rootfs_mount" && tar -czf "$rootfs_tar" --exclude="./dev/*" --exclude="./proc/*" --exclude="./sys/*" --exclude="./tmp/*" --exclude="./run/*" .); then
            local rootfs_tar_size=$(stat -c%s "$rootfs_tar")
            display_alert "Rootfs content archived" "rootfs.tar.gz size: $((rootfs_tar_size / 1024 / 1024)) MB" "info"
            display_alert "Rootfs partition contents" "Found $(find "$rootfs_mount" -type f | wc -l) files" "debug"
            ota_write_sha256_file "${ota_temp_dir}" "rootfs.tar.gz" "${rootfs_sha_file}"
        else
            umount "$rootfs_mount" 2>/dev/null || true
            display_alert "Error: Failed to create rootfs.tar.gz" "" "err"
            rm -rf "$ota_temp_dir"
            return 1
        fi
        umount "$rootfs_mount" 2>/dev/null || true
    else
        display_alert "Error: Failed to mount rootfs partition" "${rootfs_source}" "err"
        rm -rf "$ota_temp_dir"
        return 1
    fi

    # Clean up temporary mount points
    rm -rf "$boot_mount" "$rootfs_mount"

    ota_verify_extracted_archives "${ota_temp_dir}" "${secure_boot_and_decrypt}" "${boot_tar}" "${rootfs_tar}" "${boot_sha_file}" "${rootfs_sha_file}" || return 1

    # Display extraction summary
    local summary
    summary="$(ota_extraction_summary "${ota_temp_dir}" "${secure_boot_and_decrypt}" "${boot_tar}")"
    display_alert "Extraction summary" "Created $summary" "info"

    # Create final OTA package
    display_alert "Creating final OTA package" "Combining tools and images" "info"

    local base_image_name
    base_image_name="$(ota_image_package_base_name)"

    local ota_type_label
    ota_type_label="$(ota_get_package_type_label)"
    display_alert "OTA package type" "${ota_type_label}" "info"

    local ota_package_name
    ota_package_name="$(ota_image_ota_package_name "${base_image_name}")"
    local ota_output_path="${DEST}/images/${ota_package_name}"

    # Ensure output directory exists
    mkdir -p "${DEST}/images/"

    local manifest_mode
    manifest_mode="$(ota_get_manifest_mode)"

    ota_write_package_env "${ota_temp_dir}" "${manifest_mode}"

    if ! ota_copy_payload_tools "${ota_temp_dir}"; then
        rm -rf "$ota_temp_dir"
        return 1
    fi

    ota_write_ab_version_file "${ota_temp_dir}"
    ota_write_manifest "${ota_temp_dir}" "${base_image_name}" "${secure_boot_and_decrypt}" "${boot_tar}" "${rootfs_tar}"

    # Create final OTA tar.gz package
    display_alert "Creating final OTA package" "${ota_package_name}" "info"
    if ota_create_final_tarball "${ota_temp_dir}" "${ota_output_path}"; then
        local ota_size=$(stat -c%s "$ota_output_path")
        display_alert "OTA package created successfully" "${ota_package_name} ($((ota_size / 1024 / 1024)) MB)" "info"

        # Display OTA package contents
        display_alert "OTA package contents" "" "info"
        tar -tzf "$ota_output_path" | head -20 | while read -r file; do
            display_alert "  - $file" "" "info"
        done

        # Write checksums file
        local checksum_file="${DEST}/images/$(ota_image_checksum_name "${base_image_name}")"
        ota_write_package_checksums "${ota_output_path}" "${checksum_file}" "${ota_package_name}"
        display_alert "Checksums generated" "${checksum_file}" "info"

    else
        display_alert "Error: Failed to create OTA package" "${ota_package_name}" "err"
        rm -rf "$ota_temp_dir"
        return 1
    fi

    # Clean up temporary directory
    rm -rf "$ota_temp_dir"

    display_alert "OTA package creation completed" "Package: ${ota_package_name}" "info"
}
