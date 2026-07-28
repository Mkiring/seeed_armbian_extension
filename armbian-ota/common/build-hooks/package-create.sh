# OTA Package Creation Helpers

# Encrypted-payload artifact names (present only when ota_payload_encryption_enabled).
# These mirror the on-device names in common/rootfs/usr/share/armbian-ota/common.sh.
OTA_PAYLOAD_ROOTFS_ENC="rootfs.tar.gz.enc"
OTA_PAYLOAD_MANIFEST="payload.manifest"
OTA_PAYLOAD_MANIFEST_SIG="payload.manifest.sig"
# HKDF info string binding the derived key to the OTA payload use case. Must be
# identical on build host and device (ota_derive_payload_key_hex on both sides).
OTA_PAYLOAD_KDF_INFO="armbian-ota-payload-v1"
# Random AES-CBC IV produced by ota_encrypt_rootfs_payload, consumed later by
# ota_write_signed_manifest. Global so the two steps can run in separate hooks.
OTA_PAYLOAD_ENC_IV=""

function ota_require_host_tools() {
    local tool

    for tool in "$@"; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            display_alert "Error: Missing required tool" "${tool}" "err"
            return 1
        fi
    done
}

function ota_write_sha256_file() {
    local ota_temp_dir="$1"
    local image_name="$2"
    local sha_file="$3"

    (cd "${ota_temp_dir}" && sha256sum "${image_name}" > "${sha_file}") || {
        display_alert "Warning: Failed to generate SHA256 for ${image_name}" "${sha_file}" "warn"
    }
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
    local ota_security_mode="$2"
    local rootfs_tar="${ota_temp_dir}/rootfs.tar.gz"
    local enc_tar="${ota_temp_dir}/${OTA_PAYLOAD_ROOTFS_ENC}"
    local rootfs_sha_file="${ota_temp_dir}/rootfs.sha256"
    local boot_tar="${ota_temp_dir}/boot.tar.gz"
    local boot_sha_file="${ota_temp_dir}/boot.sha256"

    if ota_payload_encryption_enabled; then
        # rootfs.tar.gz has been replaced by the encrypted blob; its integrity
        # was already confirmed by the encryption round-trip, and the plaintext
        # sha256 is re-checked on the device after decryption.
        [[ -f "${enc_tar}" ]] || {
            display_alert "Error: encrypted payload missing" "${OTA_PAYLOAD_ROOTFS_ENC}" "err"
            return 1
        }
        display_alert "Archive verification completed" "Encrypted rootfs payload present (plaintext intentionally omitted)" "info"
    else
        if [[ ! -f "${rootfs_tar}" ]]; then
            display_alert "Error: rootfs.tar.gz not found" "" "err"
            return 1
        fi

        if ! tar -tzf "${rootfs_tar}" >/dev/null 2>&1; then
            display_alert "Error: rootfs.tar.gz is corrupted or invalid" "" "err"
            return 1
        fi

        ota_verify_sha256_file "${ota_temp_dir}" "${rootfs_sha_file}" "rootfs.tar.gz" || return 1
    fi

    if [[ "${ota_security_mode}" == "secure-boot-encrypted-rootfs" ]]; then
        if [[ ! -f "${ota_temp_dir}/boot.itb" ]]; then
            display_alert "Error: boot.itb is required for secure boot OTA" "" "err"
            return 1
        fi
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
    local ota_security_mode="$2"
    local boot_tar="${ota_temp_dir}/boot.tar.gz"

    if [[ "${ota_security_mode}" == "secure-boot-encrypted-rootfs" && -f "${ota_temp_dir}/boot.itb" ]]; then
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

function ota_write_version_file() {
    local ota_temp_dir="$1"
    local base_image_name="$2"
    local version_file="${ota_temp_dir}/version.txt"
    local build_commit="unknown"
    local extension_commit="unknown"

    if [[ -n "${SRC:-}" ]]; then
        build_commit="$(git -C "${SRC}" rev-parse --verify HEAD 2>/dev/null || echo unknown)"
    fi
    extension_commit="$(git -C "${OTA_SUPPORT_DIR}/.." rev-parse --verify HEAD 2>/dev/null || echo unknown)"

    cat > "${version_file}" << EOF
# Armbian OTA Package Version Info
# Generated: $(date)

ORIGINAL_IMAGE=${base_image_name}
VERSION=${IMAGE_VERSION:-"${REVISION}"}
VENDOR=${VENDOR}
BOARD=${BOARD}
RELEASE=${RELEASE}
BRANCH=${BRANCH}
KERNEL=${KERNEL_VERSION:-"${IMAGE_INSTALLED_KERNEL_VERSION}"}
BUILD_COMMIT=${build_commit}
EXTENSION_COMMIT=${extension_commit}
EOF
    display_alert "OTA package" "Created version.txt for OTA package" "info"
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

function ota_cleanup_payload_temp_dir() {
    local ota_temp_dir="$1"
    local boot_mount="${ota_temp_dir}/boot_mount"

    if [[ -d "${boot_mount}" ]] && mountpoint -q "${boot_mount}"; then
        display_alert "OTA package cleanup" "Refusing to remove active mount: ${boot_mount}" "err"
        return 1
    fi

    rm -rf "${ota_temp_dir}"
}

function ota_partition_belongs_to_loop() {
    local partition="$1"
    local parent_device

    parent_device="$(lsblk -nro PKNAME "${partition}" | head -n1)"
    [[ -n "${parent_device}" && "/dev/${parent_device}" == "${LOOP}" ]]
}

function ota_find_boot_partition() {
    local boot_partition_var="$1"
    local boot_candidate=""
    local boot_label

    for boot_label in armbi_boot boot; do
        while IFS= read -r boot_candidate; do
            if [[ -b "${boot_candidate}" ]] && ota_partition_belongs_to_loop "${boot_candidate}"; then
                printf -v "${boot_partition_var}" '%s' "${boot_candidate}"
                display_alert "Boot partition fallback" "Detected boot partition by LABEL=${boot_label}: ${boot_candidate}" "info"
                return 0
            fi
        done < <(blkid -t LABEL="${boot_label}" -o device 2>/dev/null)
    done

    while IFS= read -r boot_candidate; do
        if [[ -b "${boot_candidate}" ]] && ota_partition_belongs_to_loop "${boot_candidate}"; then
            printf -v "${boot_partition_var}" '%s' "${boot_candidate}"
            display_alert "Boot partition fallback" "Detected boot partition by PARTLABEL=boot: ${boot_candidate}" "info"
            return 0
        fi
    done < <(blkid -t PARTLABEL=boot -o device 2>/dev/null)

    return 1
}

function ota_resolve_boot_partition() {
    local ota_security_mode="$1"
    local boot_partition_var="$2"
    local boot_partition=""

    if [[ "${ota_security_mode}" == "secure-boot-encrypted-rootfs" ]]; then
        display_alert "Secure boot mode" "Skipping partition detection" "info"
    elif [[ "${AB_PART_OTA}" == "yes" ]]; then
        display_alert "AB partition OTA" "Detecting A-slot partitions" "info"

        if [[ -n "${AB_BOOT_A_PART_INDEX:-}" ]]; then
            boot_partition="${LOOP}p${AB_BOOT_A_PART_INDEX}"
            display_alert "AB partition OTA" "Using boot_a partition: ${boot_partition}" "info"
        fi
    else
        local partition_info partition_line partition_name mount_point full_path

        partition_info="$(lsblk -ln -o NAME,SIZE,MOUNTPOINT "${LOOP}" | grep -E "${LOOP##*/}p?[0-9]+" | sort)"
        if [[ -n "${partition_info}" ]]; then
            display_alert "Loop device partitions" "${partition_info}" "debug"
            while IFS= read -r partition_line; do
                [[ -n "${partition_line}" ]] || continue
                read -r partition_name _ mount_point <<<"${partition_line}"
                full_path="/dev/${partition_name}"

                if [[ -b "${full_path}" && -n "${mount_point}" ]]; then
                    if [[ "${mount_point}" == *"/boot" && -z "${boot_partition}" ]]; then
                        boot_partition="${full_path}"
                        display_alert "Detected boot partition by mount point" "${full_path} (mounted at ${mount_point})" "info"
                    fi
                fi
            done <<<"${partition_info}"
        fi
    fi

    if [[ "${ota_security_mode}" != "secure-boot-encrypted-rootfs" && -z "${boot_partition}" ]]; then
        ota_find_boot_partition boot_partition || true
    fi

    printf -v "${boot_partition_var}" '%s' "${boot_partition}"
}

function ota_report_payload_sources() {
    local ota_security_mode="$1"
    local boot_partition="$2"
    local boot_size=0

    if [[ "${ota_security_mode}" == "plain" ]]; then
        if [[ -n "${boot_partition}" ]]; then
            boot_size="$(blockdev --getsize64 "${boot_partition}" 2>/dev/null || echo 0)"
        fi
        display_alert "OTA archive sources" "boot: ${boot_partition:-none} (${boot_size} bytes), rootfs: ${MOUNT}" "info"
    elif [[ "${ota_security_mode}" == "secure-boot-encrypted-rootfs" ]]; then
        display_alert "Secure boot mode active" "Using boot.itb and rootfs: ${MOUNT}" "info"
    else
        if [[ -n "${boot_partition}" ]]; then
            boot_size="$(blockdev --getsize64 "${boot_partition}" 2>/dev/null || echo 0)"
        fi
        display_alert "Encrypted auto-decrypt mode active" "Using rootfs: ${MOUNT}, boot: ${boot_partition:-none} (${boot_size} bytes)" "info"
    fi
}

function ota_archive_directory() {
    local source_dir="$1"
    local archive="$2"
    local sha_file="$3"
    local label="$4"
    local failure_level="$5"
    shift 5
    local archive_name="$(basename "${archive}")"

    if [[ ! -d "${source_dir}" ]]; then
        display_alert "Failed to access ${label}" "${source_dir}" "${failure_level}"
        [[ "${failure_level}" == "err" ]] && return 1
        return 0
    fi

    display_alert "Extracting ${label}" "${source_dir} -> ${archive_name}" "info"
    if (cd "${source_dir}" && tar -czf "${archive}" "$@" .); then
        local archive_size
        archive_size="$(stat -c%s "${archive}")"
        display_alert "${label} archived" "${archive_name} size: $((archive_size / 1024)) KB" "info"
        display_alert "${label} contents" "Found $(find "${source_dir}" -type f | wc -l) files" "debug"
        ota_write_sha256_file "$(dirname "${archive}")" "${archive_name}" "${sha_file}"
        return 0
    fi

    display_alert "Failed to archive ${label}" "${archive_name}" "${failure_level}"
    [[ "${failure_level}" == "err" ]] && return 1
    return 0
}

function ota_archive_boot_partition() {
    local source="$1"
    local mount_dir="$2"
    shift 2
    local archive_status=0

    if ! mount "${source}" "${mount_dir}"; then
        display_alert "Failed to mount boot partition" "${source}" "warn"
        return 0
    fi

    ota_archive_directory "${mount_dir}" "$@" || archive_status=$?
    if ! umount "${mount_dir}"; then
        display_alert "Failed to unmount boot partition" "${mount_dir}" "err"
        return 1
    fi
    return "${archive_status}"
}

function ota_copy_secure_boot_itb() {
    local ota_temp_dir="$1"
    local boot_itb_source="${SRC}/cache/sources/${BOOTSOURCEDIR}/fit/boot.itb"
    local boot_itb_target="${ota_temp_dir}/boot.itb"

    if [[ ! -f "${boot_itb_source}" ]]; then
        display_alert "Error: boot.itb not found" "${boot_itb_source}" "err"
        return 1
    fi
    if ! cp "${boot_itb_source}" "${boot_itb_target}"; then
        display_alert "Error: Failed to copy boot.itb" "" "err"
        return 1
    fi

    display_alert "FIT boot image copied" "boot.itb size: $(( $(stat -c%s "${boot_itb_target}") / 1024 )) KB" "info"
    ota_write_sha256_file "${ota_temp_dir}" "boot.itb" "${ota_temp_dir}/boot.sha256"
}

# Derive a 32-byte AES-256 payload key (lowercase hex, 64 chars) from the LUKS
# passphrase via HKDF-SHA256. The same inputs yield the same key on build host
# and device (OpenSSL >= 3.0), so each side derives it independently from the
# passphrase retrieved from the security partition / OP-TEE keybox.
function ota_derive_payload_key_hex() {
    local passphrase="$1"
    local ikm_hex info_hex

    [[ -n "${passphrase}" ]] || return 1
    ikm_hex="$(printf '%s' "${passphrase}" | od -An -v -tx1 | tr -d ' \n')"
    info_hex="$(printf '%s' "${OTA_PAYLOAD_KDF_INFO}" | od -An -v -tx1 | tr -d ' \n')"
    openssl kdf -keylen 32 -binary \
        -kdfopt digest:SHA256 -kdfopt key:"${ikm_hex}" -kdfopt info:"${info_hex}" \
        HKDF | od -An -v -tx1 | tr -d ' \n'
}

# Encrypt rootfs.tar.gz into rootfs.tar.gz.enc, verify the round-trip against
# the plaintext sha256 captured at archive time, then delete the plaintext so
# only the encrypted blob ships. Sets OTA_PAYLOAD_ENC_IV for the manifest step.
function ota_encrypt_rootfs_payload() {
    local ota_temp_dir="$1"
    local plaintext_tar="${ota_temp_dir}/rootfs.tar.gz"
    local encrypted_tar="${ota_temp_dir}/${OTA_PAYLOAD_ROOTFS_ENC}"
    local sha_file="${ota_temp_dir}/rootfs.sha256"
    local expected_sha key_hex iv_hex roundtrip_sha

    [[ -f "${plaintext_tar}" ]] || {
        display_alert "OTA payload security" "rootfs.tar.gz missing, cannot encrypt" "err"
        return 1
    }
    [[ -n "${CRYPTROOT_PASSPHRASE}" ]] || {
        display_alert "OTA payload security" "CRYPTROOT_PASSPHRASE is required to encrypt the payload" "err"
        return 1
    }

    key_hex="$(ota_derive_payload_key_hex "${CRYPTROOT_PASSPHRASE}")" || {
        display_alert "OTA payload security" "Failed to derive payload key (HKDF)" "err"
        return 1
    }
    iv_hex="$(openssl rand -hex 16)" || {
        display_alert "OTA payload security" "Failed to generate AES-CBC IV" "err"
        return 1
    }

    display_alert "OTA payload security" "Encrypting rootfs.tar.gz -> ${OTA_PAYLOAD_ROOTFS_ENC} (aes-256-cbc)" "info"
    openssl enc -aes-256-cbc -K "${key_hex}" -iv "${iv_hex}" \
        -in "${plaintext_tar}" -out "${encrypted_tar}" || {
        display_alert "OTA payload security" "Payload encryption failed" "err"
        return 1
    }

    expected_sha="$(awk '{print $1}' "${sha_file}" 2>/dev/null || true)"
    roundtrip_sha="$(openssl enc -d -aes-256-cbc -K "${key_hex}" -iv "${iv_hex}" \
        -in "${encrypted_tar}" | sha256sum | awk '{print $1}')"
    [[ -n "${expected_sha}" && "${expected_sha}" = "${roundtrip_sha}" ]] || {
        display_alert "OTA payload security" "Encryption round-trip SHA256 mismatch (${expected_sha} != ${roundtrip_sha})" "err"
        return 1
    }

    rm -f "${plaintext_tar}"
    OTA_PAYLOAD_ENC_IV="${iv_hex}"
    display_alert "OTA payload security" "Encrypted payload verified (round-trip SHA256 OK), plaintext removed" "info"
}

# Write payload.manifest (encryption params + plaintext sha256) and sign it
# with the secure-boot RSA key (RSA-PSS/SHA256, matching the FIT policy). If no
# signing key is reachable the manifest is still written but left unsigned, so
# the device can decrypt without authentication (the build logs a warning).
function ota_write_signed_manifest() {
    local ota_temp_dir="$1"
    local iv_hex="$2"
    local manifest_mode="$3"
    local manifest="${ota_temp_dir}/${OTA_PAYLOAD_MANIFEST}"
    local sig="${ota_temp_dir}/${OTA_PAYLOAD_MANIFEST_SIG}"
    local rootfs_sha boot_sha privkey

    rootfs_sha="$(awk '{print $1}' "${ota_temp_dir}/rootfs.sha256" 2>/dev/null || true)"
    if [[ -f "${ota_temp_dir}/boot.sha256" ]]; then
        boot_sha="$(awk '{print $1}' "${ota_temp_dir}/boot.sha256")"
    else
        boot_sha="none"
    fi

    cat > "${manifest}" <<EOF
OTA_PAYLOAD_CIPHER=aes-256-cbc
OTA_PAYLOAD_KDF=HKDF-SHA256
OTA_PAYLOAD_KDF_INFO=${OTA_PAYLOAD_KDF_INFO}
OTA_PAYLOAD_IV=${iv_hex}
OTA_PAYLOAD_ROOTFS=${OTA_PAYLOAD_ROOTFS_ENC}
OTA_PAYLOAD_ROOTFS_SHA256=${rootfs_sha}
OTA_PAYLOAD_BOOT_SHA256=${boot_sha}
OTA_MODE=${manifest_mode}
BOARD=${BOARD}
RELEASE=${RELEASE}
VERSION=${IMAGE_VERSION:-${REVISION}}
KERNEL=${KERNEL_VERSION:-${IMAGE_INSTALLED_KERNEL_VERSION}}
EOF

    privkey="$(ota_resolve_signing_privkey 2>/dev/null)" || {
        display_alert "OTA payload security" "No signing key reachable; shipping encrypted payload WITHOUT signature" "warn"
        return 0
    }

    display_alert "OTA payload security" "Signing payload manifest with secure-boot RSA key (PSS/SHA256)" "info"
    openssl dgst -sha256 \
        -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
        -sign "${privkey}" -out "${sig}" "${manifest}" || {
        display_alert "OTA payload security" "Manifest signing failed" "err"
        return 1
    }
}

function ota_create_payload_archives() {
    local ota_temp_dir="$1"
    local ota_security_mode="$2"
    local boot_partition="$3"
    local boot_mount="${ota_temp_dir}/boot_mount"

    if [[ "${ota_security_mode}" == "secure-boot-encrypted-rootfs" ]]; then
        ota_copy_secure_boot_itb "${ota_temp_dir}" || return 1
    fi

    mkdir -p "${boot_mount}"
    if [[ -n "${boot_partition}" && "${ota_security_mode}" != "secure-boot-encrypted-rootfs" ]]; then
        if ! ota_archive_boot_partition "${boot_partition}" "${boot_mount}" "${ota_temp_dir}/boot.tar.gz" \
            "${ota_temp_dir}/boot.sha256" "boot partition" "warn"; then
            return 1
        fi
    fi

    if ! ota_archive_directory "${MOUNT}" "${ota_temp_dir}/rootfs.tar.gz" \
        "${ota_temp_dir}/rootfs.sha256" "rootfs" "err" \
        --one-file-system \
        --exclude="./dev/*" --exclude="./proc/*" --exclude="./sys/*" --exclude="./tmp/*" --exclude="./run/*"; then
        rm -rf "${boot_mount}"
        return 1
    fi

    rm -rf "${boot_mount}"
}

function ota_finalize_payload_package() {
    local ota_temp_dir="$1"
    local ota_security_mode="$2"
    local base_image_name ota_package_name ota_output_path manifest_mode checksum_file ota_size summary

    ota_verify_extracted_archives "${ota_temp_dir}" "${ota_security_mode}" || return 1
    summary="$(ota_extraction_summary "${ota_temp_dir}" "${ota_security_mode}")"
    display_alert "Extraction summary" "Created ${summary}" "info"

    display_alert "Creating final OTA package" "Combining images and metadata" "info"
    display_alert "OTA package type" "$(ota_get_package_type_label)" "info"
    base_image_name="$(ota_image_package_base_name)"
    ota_package_name="$(ota_image_ota_package_name "${base_image_name}")"
    ota_output_path="${DEST}/images/${ota_package_name}"
    manifest_mode="$(ota_get_manifest_mode)"
    mkdir -p "${DEST}/images/"

    ota_write_package_env "${ota_temp_dir}" "${manifest_mode}"
    ota_write_version_file "${ota_temp_dir}" "${base_image_name}"

    if ota_payload_encryption_enabled; then
        ota_write_signed_manifest "${ota_temp_dir}" "${OTA_PAYLOAD_ENC_IV}" "${manifest_mode}" || {
            display_alert "Error: Failed to write signed OTA payload manifest" "" "err"
            return 1
        }
    fi

    display_alert "Creating final OTA package" "${ota_package_name}" "info"
    ota_create_final_tarball "${ota_temp_dir}" "${ota_output_path}" || {
        display_alert "Error: Failed to create OTA package" "${ota_package_name}" "err"
        return 1
    }

    ota_size="$(stat -c%s "${ota_output_path}")"
    display_alert "OTA package created successfully" "${ota_package_name} ($((ota_size / 1024 / 1024)) MB)" "info"
    display_alert "OTA package contents" "" "info"
    tar -tzf "${ota_output_path}" | head -20 | while read -r file; do
        display_alert "  - ${file}" "" "info"
    done
    checksum_file="${DEST}/images/$(ota_image_checksum_name "${base_image_name}")"
    ota_write_package_checksums "${ota_output_path}" "${checksum_file}" "${ota_package_name}"
    display_alert "Checksums generated" "${checksum_file}" "info"
    display_alert "OTA package creation completed" "Package: ${ota_package_name}" "info"
}

# Build Hooks (execution order)

function pre_umount_final_image__901_create_ota_payload_pkg() {

    display_alert "pre_umount_final_image__901 Extracting partition images from loop device" "Detecting and extracting partitions from ${LOOP}" "info"

    # Determine OTA security mode.
    local ota_security_mode="plain"
    if ota_secure_boot_encrypted_rootfs_enabled; then
        ota_security_mode="secure-boot-encrypted-rootfs"
        display_alert "Secure boot and auto ota enabled" "Using FIT image workflow" "info"
    elif ota_encrypted_rootfs_enabled; then
        ota_security_mode="encrypted-rootfs"
        display_alert "Encrypted auto-decrypt OTA" "Non-secure boot mode: use mapper rootfs and package plain boot partition" "info"
    fi

    ota_require_host_tools \
        tar mount umount mountpoint lsblk grep sort blkid blockdev stat find wc \
        sha256sum md5sum awk cp head basename cat date mkdir rm || return 1

    # Create a fresh temporary directory for OTA package building.
    local ota_temp_dir="${WORKDIR}/ota_package_build_$$"
    ota_cleanup_payload_temp_dir "${ota_temp_dir}" || return 1
    mkdir -p "${ota_temp_dir}" || return 1

    # Check if loop device exists
    if [[ ! -b "${LOOP}" ]]; then
        display_alert "Error: Loop device not found" "${LOOP}" "err"
        ota_cleanup_payload_temp_dir "${ota_temp_dir}" || return 1
        return 1
    fi

    local resolved_boot_partition=""

    ota_resolve_boot_partition "${ota_security_mode}" resolved_boot_partition || {
        ota_cleanup_payload_temp_dir "${ota_temp_dir}" || return 1
        return 1
    }
    ota_report_payload_sources "${ota_security_mode}" "${resolved_boot_partition}"

    ota_create_payload_archives "${ota_temp_dir}" "${ota_security_mode}" \
        "${resolved_boot_partition}" || {
        ota_cleanup_payload_temp_dir "${ota_temp_dir}" || return 1
        return 1
    }

    if ota_payload_encryption_enabled; then
        ota_require_host_tools openssl od || {
            ota_cleanup_payload_temp_dir "${ota_temp_dir}" || return 1
            return 1
        }
        ota_encrypt_rootfs_payload "${ota_temp_dir}" || {
            ota_cleanup_payload_temp_dir "${ota_temp_dir}" || return 1
            return 1
        }
    fi

    ota_finalize_payload_package "${ota_temp_dir}" "${ota_security_mode}" || {
        ota_cleanup_payload_temp_dir "${ota_temp_dir}" || return 1
        return 1
    }

    ota_cleanup_payload_temp_dir "${ota_temp_dir}" || return 1
}
