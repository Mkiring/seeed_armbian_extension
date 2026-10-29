# Build-time recovery FIT (recovery.itb) assembly for plain recovery images.
#
# The env-prefilled scan_dev_for_boot override boots /boot/recovery/
# recovery.itb whenever ota_recovery=1 (board-verified 2026-10-28). This
# hook builds that FIT from the image's own kernel, dtb and initramfs and
# seeds it into the boot partition, so:
# - the recovery net exists from the very first boot of a fresh image;
# - every OTA package carries a current copy, because package-create
#   archives the boot partition after this hook ran (D22 fix: the package
#   boot.tar used to replace the boot files and strip hand-installed
#   recovery infrastructure).
#
# FIT shape (all board-mandated, see 中转站 D14/D20/D24):
# - external layout: mkimage -E -p 0x1000. The vendor bootm pre-process
#   parses data-offset bookkeeping and dies silently on embedded FITs;
#   external data must also sit clear of kernel_addr_r/fdt_addr_r/
#   ramdisk_addr_r, which the 0x2000000x load window in the env override
#   guarantees.
# - /images/resource carrying the board dtb as rk-kernel.dtb: vendor
#   populate_dtb reads the dtb from the FIT resource image, not from the
#   fdt image (a missing resource node fails with bootm can't read dtb,
#   ret=-1).
# - signed with the secure-boot key when available (key-name-hint=dev,
#   rk3576_rkbin mkimage: the rk3588 one silently emits unsigned FITs).
# - ramdisk is the plain initrd cpio, not the uInitrd legacy wrapper.

function ota_recovery_fit_resolve_tool() {
    local tool="$1" candidate

    local -a roots=(
        "${SRC}/cache/sources/rockchip_sdk_tools/rkbin"
        "${SRC}/cache/sources/${BOOTSOURCEDIR}/rkbin"
    )
    local -a try_dirs
    case "${tool}" in
        mkimage) try_dirs=(rk3576_rkbin/tools rk3588_rkbin/tools tools) ;;
        *)       try_dirs=(rk3576_rkbin/tools rk3588_rkbin/tools tools) ;;
    esac
    for candidate in \
        "${roots[@]/%//${try_dirs[0]}/${tool}}" \
        "${roots[@]/%//${try_dirs[1]}/${tool}}" \
        "${roots[0]}/${try_dirs[2]}/${tool}" \
        "${roots[1]}/${try_dirs[2]}/${tool}"; do
        if [[ -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

function ota_recovery_fit_stage_keys() {
    local keys_work="$1" keys_dir

    keys_dir="$(ota_resolve_signing_key_dir)" || {
        display_alert "Recovery FIT" "signing keys unavailable, FIT stays unsigned" "warn"
        return 1
    }

    mkdir -p "${keys_work}"
    install -m 0600 "${keys_dir}/private_key.pem" "${keys_work}/private_key.pem"
    if [[ -f "${keys_dir}/dev.crt" ]]; then
        install -m 0644 "${keys_dir}/dev.crt" "${keys_work}/dev.crt"
    else
        openssl req -batch -new -x509 -key "${keys_work}/private_key.pem" \
            -out "${keys_work}/dev.crt" -subj "/CN=Armbian FIT Key/" >/dev/null 2>&1 || {
            rm -rf "${keys_work}"
            return 1
        }
    fi
    # mkimage -k resolves <key-name-hint>.key / <key-name-hint>.crt.
    ln -sf private_key.pem "${keys_work}/dev.key"
    return 0
}

function pre_umount_final_image__904_recovery_seed_fit() {
    [[ "${OTA_ENABLE:-}" == "yes" && "${AB_PART_OTA:-no}" != "yes" ]] || return 0
    ota_secure_boot_encrypted_rootfs_enabled && {
        # Raw-FIT secure images enter recovery through the bootcmd raw
        # branch; their recovery entry ships once that path is verified.
        display_alert "Recovery FIT" "raw-fit image, scan-override seeding skipped" "info"
        return 0
    }
    [[ -b "${LOOP}" ]] || {
        display_alert "Recovery FIT" "loop device missing: ${LOOP}" "err"
        return 1
    }

    local mkimage_bin resource_bin
    mkimage_bin="$(ota_recovery_fit_resolve_tool mkimage)" || {
        display_alert "Recovery FIT" "signing mkimage not found (rkbin), skipping seed" "warn"
        return 0
    }
    resource_bin="$(ota_recovery_fit_resolve_tool resource_tool)" || {
        display_alert "Recovery FIT" "resource_tool not found (rkbin), skipping seed" "warn"
        return 0
    }

    local boot_partition=""
    ota_resolve_boot_partition "plain" boot_partition
    [[ -n "${boot_partition}" ]] || {
        display_alert "Recovery FIT" "boot partition not found" "err"
        return 1
    }

    local work="${WORKDIR}/ota_recovery_fit_$$"
    local boot_mount="${work}/boot"
    rm -rf "${work}"
    mkdir -p "${boot_mount}" || return 1

    if ! mount -t ext4 "${boot_partition}" "${boot_mount}"; then
        display_alert "Recovery FIT" "cannot mount ${boot_partition}" "err"
        rm -rf "${work}"
        return 1
    fi

    local kernel_image dtb_file fdtfile initrd itb ITS its_path
    kernel_image="$(find "${boot_mount}" -maxdepth 1 -name 'vmlinuz-*' | sort | tail -n1)"
    initrd="$(find "${boot_mount}" -maxdepth 1 -name 'initrd.img-*' | sort | tail -n1)"
    fdtfile="$(sed -n 's/^fdtfile=//p' "${boot_mount}/armbianEnv.txt" 2>/dev/null | tail -n1)"
    dtb_file="${boot_mount}/dtb/${fdtfile}"

    if [[ -z "${kernel_image}" || -z "${initrd}" || ! -f "${dtb_file}" ]]; then
        display_alert "Recovery FIT" "missing FIT inputs (kernel=${kernel_image:-none} initrd=${initrd:-none} dtb=${fdtfile:-none})" "err"
        umount "${boot_mount}"
        rm -rf "${work}"
        return 1
    fi

    # populate_dtb reads the dtb from the resource image and matches it by
    # the rk-kernel.dtb name the vendor toolchain expects. The tool takes
    # the output via --image=, not as a positional argument.
    mkdir -p "${work}/res"
    cp "${dtb_file}" "${work}/res/rk-kernel.dtb"
    "${resource_bin}" --pack --image="${work}/resource.img" "${work}/res/rk-kernel.dtb" >/dev/null ||
        {
            display_alert "Recovery FIT" "resource_tool pack failed" "err"
            umount "${boot_mount}"
            rm -rf "${work}"
            return 1
        }

    its_path="${work}/recovery.its"
    cat > "${its_path}" <<EOF
/dts-v1/;
/ {
    description = "Recovery OTA FIT for ${BOARD_NAME:-board}";

    images {
        fdt {
            data = /incbin/("${dtb_file}");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";
            load = <0x08300000>;
            hash { algo = "sha256"; };
        };
        kernel {
            data = /incbin/("${kernel_image}");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "none";
            entry = <0x00400000>;
            load = <0x00400000>;
            hash { algo = "sha256"; };
        };
        ramdisk {
            data = /incbin/("${initrd}");
            type = "ramdisk";
            arch = "arm64";
            os = "linux";
            compression = "none";
            load = <0x0a200000>;
            hash { algo = "sha256"; };
        };
        resource {
            data = /incbin/("${work}/resource.img");
            type = "multi";
            arch = "arm64";
            compression = "none";
            hash { algo = "sha256"; };
        };
    };

    configurations {
        default = "conf";
        conf {
            rollback-index = <0x00>;
            fdt = "fdt";
            kernel = "kernel";
            ramdisk = "ramdisk";
            multi = "resource";
            description = "Recovery OTA Image";
            signature {
                algo = "sha256,rsa2048";
                padding = "pss";
                key-name-hint = "dev";
                sign-images = "fdt", "kernel", "ramdisk", "multi";
            };
        };
    };
};
EOF

    itb="${work}/recovery.itb"
    local -a sign_args=()
    if ota_recovery_fit_stage_keys "${work}/keys"; then
        sign_args=(-k "${work}/keys" -r)
    else
        # Unsigned FIT still boots: the plain override does not gate on the
        # config signature, and hash nodes keep component integrity.
        sed -i '/signature {/,/}/d' "${its_path}"
    fi

    if ! (cd "${work}" && "${mkimage_bin}" -f recovery.its -E -p 0x1000 \
            "${sign_args[@]}" recovery.itb >"${work}/mkimage.log" 2>&1); then
        display_alert "Recovery FIT" "mkimage failed:" "err"
        cat "${work}/mkimage.log" || true
        umount "${boot_mount}"
        rm -rf "${work}"
        return 1
    fi

    mkdir -p "${boot_mount}/recovery"
    if ! cp "${itb}" "${boot_mount}/recovery/recovery.itb"; then
        display_alert "Recovery FIT" "failed to seed boot partition" "err"
        umount "${boot_mount}"
        rm -rf "${work}"
        return 1
    fi
    sync
    umount "${boot_mount}"

    display_alert "Recovery FIT" \
        "seeded recovery/recovery.itb ($(( $(stat -c%s "${itb}") / 1024 / 1024 )) MiB, $( [[ ${#sign_args[@]} -gt 0 ]] && echo signed || echo unsigned ))" "info"
    rm -rf "${work}"
    return 0
}
