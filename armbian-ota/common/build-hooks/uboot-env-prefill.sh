# Build-time U-Boot environment prefill for OTA images (A/B and recovery).
#
# Vendor U-Boot (env_blk) loads its environment from a raw area on its own
# boot disk at CONFIG_ENV_OFFSET (0x3f8000, size 0x8000, no redundant copy for
# both rk3576 and rk3588 vendor trees). Images historically shipped with that
# area blank, so every first boot ran the compiled default bootcmd behind a
# bad-CRC warning; recovery images have no runtime env writer at all, which
# left their kernel cmdline without the armbian.bootdev anchoring token and
# let multi-disk blkid first-match resolve partitions on the wrong disk.
# Prefilling a valid blob here makes every flash boot the token-carrying
# bootcmd from the start; U-Boot saveenv and ota-init writes simply overwrite
# the area later.

OTA_UBOOT_ENV_OFFSET_HEX="0x3f8000" # CONFIG_ENV_OFFSET (env/Kconfig, ARCH_ROCKCHIP)
OTA_UBOOT_ENV_SIZE_HEX="0x8000"     # CONFIG_ENV_SIZE

# mkenvimage discovery: the build container ships u-boot-tools, but fall back
# to the binary produced by any local U-Boot compilation so image-only builds
# work on bare hosts too.
function ota_uboot_env_prefill_mkenvimage() {
    local candidate

    if command -v mkenvimage >/dev/null 2>&1; then
        command -v mkenvimage
        return 0
    fi

    for candidate in "${SRC}"/cache/sources/u-boot-worktree/*/*/tools/mkenvimage; do
        if [[ -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

# Assemble the final env text for the image being built. AB images reuse the
# merged initial env written into the rootfs by pre_update_initramfs__895;
# recovery images merge the compiled default env with a bootcmd override that
# prefixes the same armbian.bootdev token the AB bootcmd carries.
function ota_uboot_env_prefill_compose() {
    local final_env="$1"
    local default_env="${UBOOT_CHROOT_DIR}/u-boot-default.env"
    local src_env bootcmd_value override_env raw_override_env

    if [[ "${AB_PART_OTA:-}" == "yes" ]]; then
        src_env="${MOUNT}/etc/u-boot-initial-env"
        [[ -f "${src_env}" ]] ||
            exit_with_error "A/B initial env missing" "${src_env} not generated"
        grep -q '^bootcmd=.*armbian\.bootdev' "${src_env}" ||
            exit_with_error "A/B initial env lacks bootdev token" "${src_env}"

        if ota_raw_boot_enabled; then
            # Raw-FIT images must take the bootcmd's raw-fit branch from the
            # very first boot. The else-branch runs distro_bootcmd first, and
            # its per-device boot_android calls repoint android_get_bootdev()
            # at whatever device was scanned last (the SPI mtd on boards with
            # NOR flash), so the trailing boot_fit then searches the wrong
            # device and dies with "No boot partition" (RK3588 SD boot,
            # 2026-09-03). ota-init only sets this mode after a bootstrapped
            # first boot, which never happens without this injection.
            raw_override_env="$(mktemp)" || exit_with_error "mktemp failed"
            printf 'ab_boot_mode=raw-fit\n' > "${raw_override_env}"
            ota_ab_merge_uboot_env_files "${final_env}" "${src_env}" "${raw_override_env}"
            rm -f "${raw_override_env}"
        else
            ota_ab_merge_uboot_env_files "${final_env}" "${src_env}"
        fi
        return 0
    fi

    [[ -f "${default_env}" ]] ||
        exit_with_error "U-Boot default env not packaged" "${default_env} missing; rebuild u-boot (./seeed-build.sh --uboot) so the deb carries u-boot-default.env"

    bootcmd_value="$(sed -n 's/^bootcmd=//p' "${default_env}" | head -n 1)"
    [[ -n "${bootcmd_value}" ]] ||
        exit_with_error "Compiled default bootcmd not found" "${default_env}"

    override_env="$(mktemp)" || exit_with_error "mktemp failed"
    if [[ "${bootcmd_value}" != *armbian.bootdev* ]]; then
        # Keep the compiled bootcmd verbatim behind the token prefix so the
        # recovery boot path stays identical to today's default-env boot,
        # except that initramfs can now anchor partition lookups.
        printf 'bootcmd=setenv bootargs "${bootargs} armbian.bootdev=${devtype} armbian.bootdevnum=${devnum}"; %s\n' \
            "${bootcmd_value}" > "${override_env}"
    fi
    if ! ota_raw_boot_enabled; then
        # Plain images enter recovery through the distro-scan override.
        # Raw-FIT (secure) images ride the bootcmd's raw-fit branch and
        # get their recovery entry once that path is board-verified.
        ota_uboot_env_recovery_scan_override >> "${override_env}"
    fi

    ota_ab_merge_uboot_env_files "${final_env}" "${default_env}" "${override_env}"
    rm -f "${override_env}"
}

# Recovery-slot entry for plain (ext4 boot) images: intercept the distro
# scan so ota_recovery=1 boots /boot/recovery/recovery.itb before any
# boot.scr runs. Board-verified 2026-10-28 (rk3588 NVMe, full auto loop).
# Design notes baked into this text:
# - Pure env: OTA packages never rewrite it, so a package boot.tar that
#   replaces boot.scr/uInitrd cannot strip the recovery net (D22).
# - Exhaustion is string-compared: vendor hush parses "test -le" operands
#   decimal-only ("0x2" reads as 0) while setexpr always stores hex
#   strings, so a numeric compare would exhaust the budget after one
#   decrement (D25).
# - The retry decrement sits AFTER ext4load succeeds: boot_targets scans
#   usb/mmc before nvme, so the override runs once per candidate device
#   and only the device actually holding the itb may consume a retry.
# - The FIT loads at 0x20000000, clear of kernel_addr_r/fdt_addr_r/
#   ramdisk_addr_r, and must be an external layout (-E -p 0x1000) FIT:
#   the vendor bootm pre-process parses data-offset bookkeeping and dies
#   silently on embedded FITs (D24).
# - console args keep the recovery session visible on the serial line:
#   this branch never runs boot.scr, which is where they normally come
#   from (observed as a silent 27s recovery session on board).
# - Every failure mode falls through to the original scan body, so a bad
#   FIT, a missing file or a broken env can never brick the board.
function ota_uboot_env_recovery_scan_override() {
    cat <<'EOF'
scan_dev_for_boot=if test "${ota_recovery}" = "1"; then if test -z "${ota_recovery_retry}" || test "${ota_recovery_retry}" = "0" || test "${ota_recovery_retry}" = "0x0"; then echo "OTA: retry exhausted, normal boot"; setenv ota_recovery 0; saveenv; else if ext4load ${devtype} ${devnum}:${distro_bootpart} 0x20000000 /recovery/recovery.itb; then setexpr ota_recovery_retry ${ota_recovery_retry} - 1; saveenv; echo "OTA: entering recovery slot (retry left ${ota_recovery_retry})"; setenv bootargs "${bootargs} ota_recovery_boot=1 console=ttyFIQ0,1500000n8"; bootm 0x20000000; echo "OTA: recovery bootm returned, falling back"; fi; fi; fi; echo Scanning ${devtype} ${devnum}:${distro_bootpart}...; for prefix in ${boot_prefixes}; do run scan_dev_for_extlinux; run scan_dev_for_scripts; done
EOF
}

# Validate that the env area fits between the u-boot loader blob and
# partition 1. Only the blob starting at sector 64 can reach the env gap
# below 4 MiB: secure images split the loader (idbloader.img at sector 64 +
# u-boot.itb at sector 16384) and the FIT lands inside partition 1 by
# design, far beyond the env area.
function ota_uboot_env_prefill_assert_layout() {
    local offset=$((OTA_UBOOT_ENV_OFFSET_HEX))
    local size=$((OTA_UBOOT_ENV_SIZE_HEX))
    local env_end_sector=$(((offset + size) / 512))
    local first_part_start uboot_end sector64_blob candidate

    ((offset % 512 == 0 && size % 512 == 0)) ||
        exit_with_error "Env geometry not sector-aligned" "offset=${OTA_UBOOT_ENV_OFFSET_HEX} size=${OTA_UBOOT_ENV_SIZE_HEX}"

    first_part_start="$(sfdisk -J "${LOOP}" 2>/dev/null |
        jq '.partitiontable.partitions | map(.start) | min')" ||
        exit_with_error "Cannot parse partition table" "sfdisk -J ${LOOP}"

    [[ "${first_part_start}" =~ ^[0-9]+$ ]] &&
        ((first_part_start >= env_end_sector)) ||
        exit_with_error "Env area overlaps partition 1" "env ends at sector ${env_end_sector}, partition 1 starts at ${first_part_start}"

    for candidate in u-boot-rockchip.bin rksd_loader.img idbloader.img; do
        if [[ -f "${UBOOT_CHROOT_DIR}/${candidate}" ]]; then
            sector64_blob="${UBOOT_CHROOT_DIR}/${candidate}"
            break
        fi
    done
    [[ -n "${sector64_blob}" ]] ||
        exit_with_error "u-boot blob not found for overlap check" "no known loader blob in ${UBOOT_CHROOT_DIR}"
    uboot_end=$((64 * 512 + $(stat -c%s "${sector64_blob}")))
    ((uboot_end <= offset)) ||
        exit_with_error "u-boot blob overlaps env area" "$(basename "${sector64_blob}") ends at ${uboot_end}, env starts at ${offset}"
}

# Read the blob back from the image and verify CRC + token, then log the
# bootcmd that will run on first boot.
function ota_uboot_env_prefill_verify() {
    local loop="$1" seek_sector="$2" size="$3"
    local env_info

    env_info="$(dd if="${loop}" bs=512 skip="${seek_sector}" count="$((size / 512))" status=none |
        python3 -c '
import struct, sys, zlib
blob = sys.stdin.buffer.read()
crc = struct.unpack("<I", blob[:4])[0]
if (zlib.crc32(blob[4:]) & 0xFFFFFFFF) != crc:
    sys.exit("env blob CRC mismatch after write")
for entry in blob[4:].split(b"\0"):
    if not entry:
        break
    print(entry.decode("utf-8", "replace"))
')" || exit_with_error "Env blob readback failed" "${env_info}"
    grep -q '^bootcmd=.*armbian\.bootdev' <<< "${env_info}" ||
        exit_with_error "Prefilled env lacks bootdev token" "bootcmd not carried into blob"
    if ! ota_raw_boot_enabled; then
        grep -q '^scan_dev_for_boot=.*ota_recovery' <<< "${env_info}" ||
            exit_with_error "Prefilled env lacks recovery scan override" "scan_dev_for_boot not carried into blob"
    fi

    display_alert "OTA U-Boot env prefill" "$(grep '^bootcmd=' <<< "${env_info}")" "info"
}

function post_write_uboot_platform__910_prefill_uboot_env() {
    local offset=$((OTA_UBOOT_ENV_OFFSET_HEX))
    local size=$((OTA_UBOOT_ENV_SIZE_HEX))
    local seek_sector=$((offset / 512))
    local mkenvimage_bin final_env blob

    mkenvimage_bin="$(ota_uboot_env_prefill_mkenvimage)" ||
        exit_with_error "mkenvimage not found" "install u-boot-tools or run a u-boot build first"

    final_env="$(mktemp)" || exit_with_error "mktemp failed"
    blob="$(mktemp)" || exit_with_error "mktemp failed"

    ota_uboot_env_prefill_compose "${final_env}"
    ota_uboot_env_prefill_assert_layout

    "${mkenvimage_bin}" -s "${size}" -o "${blob}" "${final_env}" ||
        exit_with_error "mkenvimage failed" "${mkenvimage_bin}"
    [[ "$(stat -c%s "${blob}")" == "${size}" ]] ||
        exit_with_error "Unexpected blob size" "$(stat -c%s "${blob}") != ${size}"

    dd if="${blob}" of="${LOOP}" bs=512 seek="${seek_sector}" conv=notrunc status=none ||
        exit_with_error "Failed to write env blob" "${LOOP} @ ${OTA_UBOOT_ENV_OFFSET_HEX}"
    sync

    ota_uboot_env_prefill_verify "${LOOP}" "${seek_sector}" "${size}"

    rm -f "${final_env}" "${blob}"
    display_alert "OTA U-Boot env prefill" "Wrote ${size} bytes at offset ${OTA_UBOOT_ENV_OFFSET_HEX}" "info"
}
