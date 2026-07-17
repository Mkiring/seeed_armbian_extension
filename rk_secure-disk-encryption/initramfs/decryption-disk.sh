#!/bin/sh
#
# initramfs-tools init-top hook: unlock encrypted root from the security partition.

export SECURITY_STORAGE=SECURITY

BN_DIR="/dev/block/by-name"
SYSPW_FILE="/tmp/syspw"
MAPPER_NAME="armbian-root"
TEE_SUPPLICANT_PID=""

log_step() {
    echo "$*"
    [ -e /dev/kmsg ] && echo "$*" > /dev/kmsg 2>/dev/null || true
}

first_line() {
    while IFS= read -r line; do
        printf '%s\n' "$line"
        return 0
    done
    return 1
}

get_cmdline_crypt_uuid() {
    local token value

    for token in $(cat /proc/cmdline 2>/dev/null); do
        case "$token" in
            cryptdevice=UUID=*:*)
                value="${token#cryptdevice=UUID=}"
                echo "${value%%:*}"
                return 0
                ;;
            cryptdevice=UUID=*)
                echo "${token#cryptdevice=UUID=}"
                return 0
                ;;
        esac
    done

    return 1
}

get_cmdline_ab_slot() {
    local token

    for token in $(cat /proc/cmdline 2>/dev/null); do
        case "$token" in
            armbian.slot=a|armbian.slot=b)
                echo "${token#armbian.slot=}"
                return 0
                ;;
        esac
    done

    return 1
}

get_luks_device_by_partlabel() {
    local partlabel="$1"
    local dev

    dev="$(blkid -t PARTLABEL="$partlabel" -o device 2>/dev/null | first_line || true)"
    if [ -n "$dev" ] && [ "$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)" = "crypto_LUKS" ]; then
        echo "$dev"
    fi
}

keybox_ready() {
    [ -x /usr/bin/keybox_app ] &&
        [ -x /usr/bin/tee-supplicant ] &&
        [ -e /dev/tee0 ] &&
        [ -e /dev/teepriv0 ]
}

start_tee_supplicant() {
    keybox_ready || return 1
    /usr/bin/tee-supplicant >/dev/null 2>&1 &
    TEE_SUPPLICANT_PID="$!"
    log_step "[Decryption-disk] tee-supplicant started"
}

stop_tee_supplicant() {
    if [ -n "$TEE_SUPPLICANT_PID" ] && kill -0 "$TEE_SUPPLICANT_PID" 2>/dev/null; then
        kill "$TEE_SUPPLICANT_PID" >/dev/null 2>&1 || true
        wait "$TEE_SUPPLICANT_PID" 2>/dev/null || true
    fi
    TEE_SUPPLICANT_PID=""
}

log_step "[Decryption-disk] ENTER 0-decryption-disk"

SECURITY_DEV="$(blkid -t PARTLABEL=security -o device 2>/dev/null | first_line || true)"
if [ -z "$SECURITY_DEV" ]; then
    log_step "[Decryption-disk] Error: cannot resolve security partition by PARTLABEL=security"
    blkid 2>/dev/null || true
    exit 1
fi

mkdir -p "$BN_DIR" 2>/dev/null || true
ln -sf "$SECURITY_DEV" "${BN_DIR}/security" 2>/dev/null || true
log_step "[Decryption-disk] security partition resolved: ${SECURITY_DEV}"

rm -f "$SYSPW_FILE" 2>/dev/null || true
SECURITY_MARKER="$(dd if="$SECURITY_DEV" bs=1 count=4 2>/dev/null || true)"
log_step "[Decryption-disk] Security partition marker: ${SECURITY_MARKER:-<empty>}"

if [ "$SECURITY_MARKER" = "SSKR" ]; then
    log_step "[Decryption-disk] SSKR marker found, reading passphrase with keybox_app"
    if ! start_tee_supplicant; then
        log_step "[Decryption-disk] Error: SSKR marker requires working OP-TEE and keybox_app"
        exit 1
    fi

    if ! /usr/bin/keybox_app >/dev/null 2>&1; then
        stop_tee_supplicant
        log_step "[Decryption-disk] Error: keybox_app read failed"
        exit 1
    fi
    stop_tee_supplicant
else
    log_step "[Decryption-disk] No SSKR marker, reading raw passphrase"
    dd if="$SECURITY_DEV" of="$SYSPW_FILE" bs=1 count=64 2>/dev/null || {
        log_step "[Decryption-disk] Error: failed to read raw passphrase"
        exit 1
    }
    chmod 600 "$SYSPW_FILE" 2>/dev/null || true

    if keybox_ready && start_tee_supplicant; then
        /usr/bin/keybox_app write >/dev/null 2>&1 ||
            log_step "[Decryption-disk] keybox_app write failed, keeping raw passphrase"
        stop_tee_supplicant
    else
        log_step "[Decryption-disk] OP-TEE keybox path unavailable, using raw passphrase"
    fi
fi

if [ ! -s "$SYSPW_FILE" ]; then
    log_step "[Decryption-disk] Error: Failed to retrieve password from security partition"
    exit 1
fi
log_step "[Decryption-disk] Password successfully retrieved from security partition"

ROOT_DEVICE=""
TARGET_LUKS_UUID="$(get_cmdline_crypt_uuid || true)"
if [ -n "$TARGET_LUKS_UUID" ]; then
    ROOT_DEVICE="$(blkid -t UUID="$TARGET_LUKS_UUID" -o device 2>/dev/null | first_line || true)"
    if [ -n "$ROOT_DEVICE" ] && [ "$(blkid -s TYPE -o value "$ROOT_DEVICE" 2>/dev/null || true)" != "crypto_LUKS" ]; then
        ROOT_DEVICE=""
    fi
fi

# A/B images use a stable GPT PARTLABEL for each slot. The LUKS UUID is
# device-local and may differ from the UUID known when a signed boot.itb was
# built, so select the requested slot before falling back to arbitrary LUKS
# discovery. First boot has no persistent U-Boot environment yet and defaults
# to the populated A slot.
if [ -z "$ROOT_DEVICE" ]; then
    AB_SLOT="$(get_cmdline_ab_slot || true)"
    case "$AB_SLOT" in
        a|b)
            ROOT_DEVICE="$(get_luks_device_by_partlabel "rootfs_$AB_SLOT" || true)"
            ;;
        *)
            ROOT_DEVICE="$(get_luks_device_by_partlabel "rootfs_a" || true)"
            ;;
    esac
fi

[ -n "$ROOT_DEVICE" ] || ROOT_DEVICE="$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | first_line || true)"
if [ -z "$ROOT_DEVICE" ]; then
    log_step "[Decryption-disk] Error: No LUKS partition found"
    blkid 2>/dev/null || true
    exit 1
fi

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEVICE" 2>/dev/null || true)"
log_step "[Decryption-disk] Found LUKS device: ${ROOT_DEVICE} (UUID: ${ROOT_UUID:-unknown})"
log_step "[Decryption-disk] Unlocking LUKS encrypted partition"

/sbin/cryptsetup luksOpen "$ROOT_DEVICE" "$MAPPER_NAME" < "$SYSPW_FILE" || {
    log_step "[Decryption-disk] Error: Failed to unlock LUKS partition"
    exit 1
}

log_step "[Decryption-disk] root mapper ready: /dev/mapper/${MAPPER_NAME}"
log_step "[Decryption-disk] LUKS partition unlocked successfully"
