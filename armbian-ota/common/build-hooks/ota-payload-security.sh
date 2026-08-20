# OTA payload encryption + signing build hooks.
#
# When the rootfs is encrypted (CRYPTROOT_ENABLE=yes + RK_AUTO_DECRYP=yes) the
# OTA payload (rootfs.tar.gz) is itself plaintext, which leaks the full rootfs
# over the distribution channel and defeats LUKS at-rest protection. These
# helpers let the packaging stage encrypt the payload (AES-256-CBC, key derived
# via HKDF from the LUKS passphrase) and sign a manifest with the secure-boot
# RSA key, so the device can both decrypt and authenticate the update.
#
# Decryption and signature verification happen on-device in the rootfs runtime
# phase (A/B ab_start_ota / Recovery recovery_start_ota). The Recovery initramfs
# apply stage only extracts the already-decrypted plaintext tar, so no openssl
# is needed in the initramfs.

# Payload encryption mirrors the on-device auto-decrypt capability: only when
# the device can retrieve the passphrase unattended (security partition /
# OP-TEE keybox) can it decrypt the payload at OTA time.
function ota_payload_encryption_enabled() {
    ota_encrypted_rootfs_enabled
}

# Resolve the secure-boot signing key directory. The keys are generated during
# the U-Boot build phase; at image/packaging time we reach them through, in
# order: a caller-supplied persistent backup dir, the export left by the
# secure-boot hook, or the original U-Boot source tree under SRC/cache/sources
# (the same cross-phase cache ota_copy_secure_boot_itb relies on for boot.itb).
function ota_resolve_signing_key_dir() {
    local candidate

    for candidate in \
        "${UBOOT_FIT_KEYS_BACKUP_DIR:-}" \
        "${UBOOT_FIT_KEYS_DIR:-}" \
        "${SRC}/cache/sources/${BOOTSOURCEDIR}/keys"
    do
        [[ -n "${candidate}" && -f "${candidate}/private_key.pem" && -f "${candidate}/public_key.pem" ]] || continue
        echo "${candidate}"
        return 0
    done

    return 1
}

function ota_resolve_signing_privkey() {
    local keys_dir
    keys_dir="$(ota_resolve_signing_key_dir)" || return 1
    echo "${keys_dir}/private_key.pem"
}

function ota_resolve_signing_pubkey() {
    local keys_dir
    keys_dir="$(ota_resolve_signing_key_dir)" || return 1
    echo "${keys_dir}/public_key.pem"
}

# Install openssl on the target. The same binary performs payload decryption
# (AES-256-CBC) and manifest signature verification (RSA-PSS) at OTA time.
function extension_prepare_config__install_ota_payload_crypto() {
    if ! ota_payload_encryption_enabled; then
        return 0
    fi
    display_alert "OTA payload security" "Installing openssl for payload decryption and signature verification" "info"
    add_packages_to_image openssl
}

# Embed the OTA payload verification public key into the rootfs so the device
# can authenticate the signed manifest. Runs before the packaging hook (901).
function pre_umount_final_image__897_install_ota_payload_pubkey() {
    local pubkey_src pubkey_dir

    if ! ota_payload_encryption_enabled; then
        return 0
    fi

    pubkey_src="$(ota_resolve_signing_pubkey 2>/dev/null)" || {
        display_alert "OTA payload security" "Secure-boot signing key not found; payload will be encrypted but NOT signed" "warn"
        display_alert "OTA payload security" "Provide UBOOT_FIT_KEYS_BACKUP_DIR or enable OP-TEE/secure-boot key generation to sign OTA payloads" "warn"
        return 0
    }

    pubkey_dir="${MOUNT}/usr/share/armbian-ota/keys"
    mkdir -p "${pubkey_dir}"
    install -m 0644 "${pubkey_src}" "${pubkey_dir}/ota-payload.pub.pem" ||
        exit_with_error "Failed to install OTA payload verification public key"
    display_alert "OTA payload security" "Installed OTA payload verification public key into rootfs" "info"
}
