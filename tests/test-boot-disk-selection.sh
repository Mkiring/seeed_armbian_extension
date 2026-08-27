#!/usr/bin/env bash
#
# Host-side unit tests for multi-disk boot-device selection and env prefill.
#
# Covers the pure selection helpers from the initramfs decryption hook (the
# blkid-driven functions that decided which physical disk supplies the
# security/root/userdata partitions), the env-text merge used by the build
# hooks, and the mkenvimage blob round-trip that the image prefill relies on.
# sysfs-dependent helpers (parent_disk_of and friends) are exercised on the
# bench instead; everything here runs on the build host with mocked blkid.

EXT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
ko() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }

assert_eq() {
    local what="$1" got="$2" want="$3"
    if [[ "${got}" == "${want}" ]]; then
        ok
    else
        ko "${what}: got '${got}' want '${want}'"
    fi
}

assert_contains() {
    local what="$1" got="$2" needle="$3"
    if [[ "${got}" == *"${needle}"* ]]; then
        ok
    else
        ko "${what}: '${got}' lacks '${needle}'"
    fi
}

# ── mocked environment ───────────────────────────────────────────────────────

MOCK_CMDLINE=""
MOCK_BLKID_TABLE=""
MOCK_DEVICES="/dev/mmcblk1 /dev/nvme0n1"

cat() {
    if [[ "${1:-}" == "/proc/cmdline" ]]; then
        printf '%s\n' "${MOCK_CMDLINE}"
        return 0
    fi
    command cat "$@"
}

# The selection helpers validate token disks with [ -b ]; the build host has
# no such nodes, so route block-existence checks through MOCK_DEVICES.
[() {
    if [[ "${1:-}" == "-b" && "${2:-}" == /dev/* ]]; then
        local dev
        for dev in ${MOCK_DEVICES}; do
            [[ "${2}" == "${dev}" ]] && return 0
        done
        return 1
    fi
    builtin [ "$@"
}

# Table format: one entry per line, "device KEY=VALUE KEY=VALUE ...".
# Supports the two blkid forms the selection helpers use:
#   blkid -t KEY=VALUE -o device          -> matching devices, table order
#   blkid -s PROP -o value DEVICE         -> property value for DEVICE
blkid() {
    local opt filter prop value dev entry
    while getopts ":t:s:o:" opt; do
        case "${opt}" in
            t) filter="${OPTARG}" ;;
            s) prop="${OPTARG}" ;;
            o) value="${OPTARG}" ;;
            *) return 1 ;;
        esac
    done
    shift $((OPTIND - 1))

    if [[ -n "${filter}" ]]; then
        while read -r entry; do
            [[ -z "${entry}" ]] && continue
            local dev="${entry%% *}"
            local attrs="${entry#* }"
            [[ " ${attrs} " == *" ${filter} "* ]] && printf '%s\n' "${dev}"
        done <<< "${MOCK_BLKID_TABLE}"
        return 0
    fi

    if [[ -n "${prop}" ]]; then
        local dev="${1:-}"
        while read -r entry; do
            [[ "${entry%% *}" == "${dev}" ]] || continue
            local attrs="${entry#* }"
            local a
            for a in ${attrs}; do
                [[ "${a}" == "${prop}="* ]] && printf '%s\n' "${a#${prop}=}"
            done
        done <<< "${MOCK_BLKID_TABLE}"
        return 0
    fi

    return 1
}

# Source the initramfs helpers: everything before the "ENTER" log line is
# function definitions only, so the mocked harness can source it safely.
DEC_FUNCS="$(mktemp)"
sed '/^log_step "\[Decryption-disk\] ENTER/,$d' \
    "${EXT_ROOT}/rk_secure-disk-encryption/initramfs/decryption-disk.sh" > "${DEC_FUNCS}"
# shellcheck source=/dev/null
source "${DEC_FUNCS}"

# ── cmdline token parsing ────────────────────────────────────────────────────

MOCK_CMDLINE="console=ttyFIQ0 root=/dev/mapper/armbian-root rw armbian.bootdev=mmc armbian.bootdevnum=1"
assert_eq "token mmc1" "$(get_cmdline_boot_disk)" "/dev/mmcblk1"

MOCK_CMDLINE="armbian.bootdev=nvme armbian.bootdevnum=0"
assert_eq "token nvme0" "$(get_cmdline_boot_disk)" "/dev/nvme0n1"

MOCK_CMDLINE="console=ttyFIQ0 root=/dev/mapper/armbian-root rw"
assert_eq "no token" "$(get_cmdline_boot_disk || echo NONE)" "NONE"

MOCK_CMDLINE="armbian.bootdev=mmc armbian.bootdevnum=9"
assert_eq "bogus token" "$(get_cmdline_boot_disk || echo NONE)" "NONE"

MOCK_CMDLINE="cryptdevice=UUID=6d1ea694-a67c-4b3e-a590-62b0c4460986:root armbian.slot=b"
assert_eq "crypt uuid" "$(get_cmdline_crypt_uuid)" "6d1ea694-a67c-4b3e-a590-62b0c4460986"
assert_eq "ab slot" "$(get_cmdline_ab_slot)" "b"

# ── partition selection matrix ───────────────────────────────────────────────
# Clone scenario: NVMe registered before SD, identical PARTLABEL/UUID payloads.

CLONE_TABLE="/dev/nvme0n1p2 PARTLABEL=security TYPE=crypto_LUKS
/dev/nvme0n1p3 PARTLABEL=rootfs UUID=6d1ea694-a67c-4b3e-a590-62b0c4460986 TYPE=crypto_LUKS
/dev/nvme0n1p4 PARTLABEL=userdata UUID=6b4cea5e-087f-4cd7-8677-0cd7be147775 TYPE=crypto_LUKS
/dev/mmcblk1p2 PARTLABEL=security TYPE=crypto_LUKS
/dev/mmcblk1p3 PARTLABEL=rootfs UUID=6d1ea694-a67c-4b3e-a590-62b0c4460986 TYPE=crypto_LUKS
/dev/mmcblk1p4 PARTLABEL=userdata UUID=6b4cea5e-087f-4cd7-8677-0cd7be147775 TYPE=crypto_LUKS"
MOCK_BLKID_TABLE="${CLONE_TABLE}"

# Unanchored: blkid table order wins (the 2026-08-27 bench failure).
assert_eq "clone no token security" "$(first_match_on_disk PARTLABEL=security)" "/dev/nvme0n1p2"
assert_eq "clone no token userdata" "$(get_luks_device_by_partlabel userdata)" "/dev/nvme0n1p4"

# Anchored to SD: every lookup follows the token despite NVMe being first.
BOOT_DISK="/dev/mmcblk1"
assert_eq "clone token security" "$(first_match_on_disk PARTLABEL=security "${BOOT_DISK}")" "/dev/mmcblk1p2"
assert_eq "clone token rootfs" "$(get_luks_device_by_partlabel rootfs "${BOOT_DISK}")" "/dev/mmcblk1p3"
assert_eq "clone token userdata" "$(get_luks_device_by_partlabel userdata "${BOOT_DISK}")" "/dev/mmcblk1p4"
unset BOOT_DISK

# Anchored to NVMe (image cloned the other way round).
BOOT_DISK="/dev/nvme0n1"
assert_eq "clone token-nvme userdata" "$(get_luks_device_by_partlabel userdata "${BOOT_DISK}")" "/dev/nvme0n1p4"
unset BOOT_DISK

# Plain foreign disk: its ext4 rootfs/userdata must never satisfy a LUKS
# lookup even without a token (d9465e8d regression guard).
PLAIN_TABLE="/dev/nvme0n1p3 PARTLABEL=rootfs TYPE=ext4
/dev/nvme0n1p4 PARTLABEL=userdata TYPE=ext4
/dev/mmcblk1p3 PARTLABEL=rootfs UUID=6d1ea694-a67c-4b3e-a590-62b0c4460986 TYPE=crypto_LUKS
/dev/mmcblk1p4 PARTLABEL=userdata TYPE=crypto_LUKS"
MOCK_BLKID_TABLE="${PLAIN_TABLE}"
assert_eq "plain-foreign userdata" "$(get_luks_device_by_partlabel userdata)" "/dev/mmcblk1p4"

# Mixed-layout scenario (2026-08-27 matrix failure): recovery boot disk has
# no rootfs_a, a foreign encrypted A/B disk does. With a token the slot
# fallback must come up empty instead of defecting to the foreign disk, and
# the plain rootfs label on the boot disk must win.
MIXED_TABLE="/dev/nvme0n1p3 PARTLABEL=boot_a TYPE=ext4
/dev/nvme0n1p4 PARTLABEL=rootfs_a TYPE=crypto_LUKS
/dev/nvme0n1p5 PARTLABEL=rootfs_b TYPE=crypto_LUKS
/dev/nvme0n1p6 PARTLABEL=userdata TYPE=crypto_LUKS
/dev/mmcblk1p2 PARTLABEL=security TYPE=crypto_LUKS
/dev/mmcblk1p3 PARTLABEL=rootfs TYPE=crypto_LUKS
/dev/mmcblk1p4 PARTLABEL=userdata TYPE=crypto_LUKS"
MOCK_BLKID_TABLE="${MIXED_TABLE}"
BOOT_DISK="/dev/mmcblk1"
assert_eq "mixed token slot fallback empty" "$(get_luks_device_by_partlabel rootfs_a || echo NONE)" "NONE"
assert_eq "mixed token rootfs" "$(get_luks_device_by_partlabel rootfs)" "/dev/mmcblk1p3"
unset BOOT_DISK

# Legacy no-token boot keeps the old any-disk behavior.
assert_eq "mixed no-token slot fallback" "$(get_luks_device_by_partlabel rootfs_a)" "/dev/nvme0n1p4"

# Single disk: token or not, same result.
MOCK_BLKID_TABLE="/dev/mmcblk1p3 PARTLABEL=rootfs TYPE=crypto_LUKS"
assert_eq "single disk" "$(get_luks_device_by_partlabel rootfs)" "/dev/mmcblk1p3"

# ── env text merge (build hook helper) ──────────────────────────────────────

display_alert() { :; }
# shellcheck source=/dev/null
source "${EXT_ROOT}/armbian-ota/common/build-hooks/uboot-default-env.sh"

MERGE_OUT="$(mktemp)"
printf '%s\n' \
    "# comment line" \
    "bootcmd=boot_fit;" \
    "bootdelay=0" \
    "" > "${MERGE_OUT}.a"
printf '%s\n' \
    "bootdelay=1" \
    "bootcmd=setenv bootargs \"\${bootargs} armbian.bootdev=\${devtype}\"; boot_fit;" \
    "novel_key=1" > "${MERGE_OUT}.b"
ota_ab_merge_uboot_env_files "${MERGE_OUT}" "${MERGE_OUT}.a" "${MERGE_OUT}.b"
merged="$(cat "${MERGE_OUT}")"
assert_eq "merge strips comments and keeps order" \
    "$(head -n1 <<< "${merged}")" "bootcmd=setenv bootargs \"\${bootargs} armbian.bootdev=\${devtype}\"; boot_fit;"
assert_eq "merge last-wins" "$(grep -c '^bootdelay=1$' <<< "${merged}"; grep -c '^bootdelay=0$' <<< "${merged}" || true)" "1
0"
assert_eq "merge keeps novel keys" "$(grep -c '^novel_key=1$' <<< "${merged}")" "1"

# ── prefill compose (recovery + A/B) ─────────────────────────────────────────

PREFILL_TMP="$(mktemp -d)"
exit_with_error() { echo "EXIT_WITH_ERROR: $*"; exit 23; }
# shellcheck source=/dev/null
# partitions.sh provides ota_raw_boot_enabled, which the build sources via
# ota-support.sh before this module.
# shellcheck source=/dev/null
source "${EXT_ROOT}/armbian-ota/common/build-hooks/partitions.sh"
# shellcheck source=/dev/null
source "${EXT_ROOT}/armbian-ota/common/build-hooks/uboot-env-prefill.sh"

# Recovery: default env gets the token prefix in front of the compiled bootcmd.
UBOOT_CHROOT_DIR="${PREFILL_TMP}/uboot"
mkdir -p "${UBOOT_CHROOT_DIR}"
printf '%s\n' "bootargs=console=ttyFIQ0 root=/dev/mapper/armbian-root rw" "bootcmd=boot_fit;" "bootdelay=0" \
    > "${UBOOT_CHROOT_DIR}/u-boot-default.env"
out="$(ota_uboot_env_prefill_compose "${PREFILL_TMP}/rec.env"; echo rc=$?)"
composed="$(cat "${PREFILL_TMP}/rec.env")"
assert_eq "recovery compose rc" "${out##*rc=}" "0"
assert_contains "recovery token bootcmd" "$(grep '^bootcmd=' <<< "${composed}")" 'armbian.bootdev=${devtype} armbian.bootdevnum=${devnum}'
assert_eq "recovery bootcmd tail" "$(grep '^bootcmd=' <<< "${composed}")" 'bootcmd=setenv bootargs "${bootargs} armbian.bootdev=${devtype} armbian.bootdevnum=${devnum}"; boot_fit;'
assert_eq "recovery bootdelay" "$(grep '^bootdelay=' <<< "${composed}")" "bootdelay=1"

# Recovery with an already tokenized default bootcmd: kept verbatim.
printf '%s\n' "bootcmd=setenv bootargs \"\${bootargs} armbian.bootdev=\${devtype}\"; boot_fit;" \
    > "${UBOOT_CHROOT_DIR}/u-boot-default.env"
ota_uboot_env_prefill_compose "${PREFILL_TMP}/rec2.env"
assert_eq "recovery idempotent bootcmd" "$(grep -c 'armbian.bootdev' <<< "$(cat "${PREFILL_TMP}/rec2.env")")" "1"

# Missing packaged default env: loud failure.
rm -f "${UBOOT_CHROOT_DIR}/u-boot-default.env"
out="$(ota_uboot_env_prefill_compose "${PREFILL_TMP}/rec3.env" 2>&1; echo rc=$?)"
assert_contains "missing default env" "${out}" "EXIT_WITH_ERROR"

# A/B: rootfs initial env is passed through cleaned, token required.
MOUNT="${PREFILL_TMP}/rootfs"
mkdir -p "${MOUNT}/etc"
printf '%s\n' "# seed" "bootdelay=1" \
    'bootcmd=run ab_preboot; setenv bootargs "${bootargs} armbian.bootdev=${devtype} armbian.bootdevnum=${devnum}"; boot_fit;' \
    > "${MOUNT}/etc/u-boot-initial-env"
AB_PART_OTA=yes out="$(ota_uboot_env_prefill_compose "${PREFILL_TMP}/ab.env"; echo rc=$?)"
assert_eq "ab compose rc" "${out##*rc=}" "0"
assert_contains "ab token bootcmd" "$(grep '^bootcmd=' <<< "$(cat "${PREFILL_TMP}/ab.env")")" "armbian.bootdev="
assert_eq "ab no comments" "$(grep -c '^#' <<< "$(cat "${PREFILL_TMP}/ab.env")" || true)" "0"
unset AB_PART_OTA MOUNT UBOOT_CHROOT_DIR

# A/B seed without token must be rejected.
MOUNT="${PREFILL_TMP}/rootfs2"
mkdir -p "${MOUNT}/etc"
printf '%s\n' "bootcmd=boot_fit;" > "${MOUNT}/etc/u-boot-initial-env"
AB_PART_OTA=yes out="$(ota_uboot_env_prefill_compose "${PREFILL_TMP}/ab2.env" 2>&1; echo rc=$?)"
assert_contains "ab token enforcement" "${out}" "EXIT_WITH_ERROR"
unset AB_PART_OTA MOUNT

# A/B raw-fit builds must inject the boot mode so first boot takes the
# raw-fit branch and never runs the distro scan (android_dev_desc poison).
MOUNT="${PREFILL_TMP}/rootfs3"
mkdir -p "${MOUNT}/etc"
printf '%s\n' "bootdelay=1" \
    'bootcmd=run ab_preboot; setenv bootargs "${bootargs} armbian.bootdev=${devtype} armbian.bootdevnum=${devnum}"; boot_fit;' \
    > "${MOUNT}/etc/u-boot-initial-env"
AB_PART_OTA=yes BOOT_RAW_MODE=yes ota_uboot_env_prefill_compose "${PREFILL_TMP}/ab3.env"
assert_eq "ab raw-fit mode injected" "$(grep -c '^ab_boot_mode=raw-fit$' "${PREFILL_TMP}/ab3.env")" "1"
unset AB_PART_OTA BOOT_RAW_MODE MOUNT

# Plain A/B (BOOT_RAW_MODE unset) must NOT carry the mode: first boot needs
# the distro scan to reach boot.scr on the ext4 boot_a partition.
MOUNT="${PREFILL_TMP}/rootfs4"
mkdir -p "${MOUNT}/etc"
printf '%s\n' \
    'bootcmd=run ab_preboot; setenv bootargs "${bootargs} armbian.bootdev=${devtype}"; boot_fit;' \
    > "${MOUNT}/etc/u-boot-initial-env"
AB_PART_OTA=yes ota_uboot_env_prefill_compose "${PREFILL_TMP}/ab4.env"
assert_eq "plain ab keeps distro path" "$(grep -c '^ab_boot_mode=' "${PREFILL_TMP}/ab4.env")" "0"
unset AB_PART_OTA MOUNT

# ── mkenvimage round-trip ────────────────────────────────────────────────────

MKENVIMAGE="$(command -v mkenvimage || true)"
if [[ -z "${MKENVIMAGE}" ]]; then
    for candidate in "${EXT_ROOT}/../armbian-build/cache/sources/u-boot-worktree"/*/*/tools/mkenvimage; do
        [[ -x "${candidate}" ]] && MKENVIMAGE="${candidate}" && break
    done
fi
if [[ -n "${MKENVIMAGE}" ]]; then
    "${MKENVIMAGE}" -s 32768 -o "${PREFILL_TMP}/blob" "${PREFILL_TMP}/rec.env" 2>/dev/null ||
        ko "mkenvimage invocation failed"
    parsed="$(python3 - "${PREFILL_TMP}/blob" <<'PYEOF'
import struct, sys, zlib
blob = open(sys.argv[1], "rb").read()
crc = struct.unpack("<I", blob[:4])[0]
print("CRC-OK" if (zlib.crc32(blob[4:]) & 0xFFFFFFFF) == crc else "CRC-BAD")
print("SIZE-OK" if len(blob) == 32768 else "SIZE-BAD")
for entry in blob[4:].split(b"\0"):
    if not entry:
        break
    print(entry.decode())
PYEOF
)"
    assert_eq "blob crc" "$(grep '^CRC-' <<< "${parsed}")" "CRC-OK"
    assert_eq "blob size" "$(grep '^SIZE-' <<< "${parsed}")" "SIZE-OK"
    assert_contains "blob bootcmd token" "$(grep '^bootcmd=' <<< "${parsed}")" 'armbian.bootdev'
    assert_eq "blob bootdelay" "$(grep '^bootdelay=' <<< "${parsed}")" "bootdelay=1"
else
    echo "SKIP: mkenvimage not found on host or build cache"
fi

# ── summary ─────────────────────────────────────────────────────────────────

rm -rf "${PREFILL_TMP}" "${MERGE_OUT}" "${MERGE_OUT}.a" "${MERGE_OUT}.b" "${DEC_FUNCS}"
echo "passed=${PASS} failed=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
