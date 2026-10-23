#
# OTA hook: keep the on-device kernel across a rootfs-only OTA (OTA_HOOK_API=1).
#
# Stage with the build variable
#   OTA_HOOK_SCRIPT=<extension>/armbian-ota/recovery/hooks/keep-modules.sh
# and ship the package WITHOUT a boot.tar member (no boot payload -> the
# built-in apply never mounts or writes the boot partition; kernel/initrd
# stay exactly as they are).
#
# hook_pre_apply  backs up /lib/modules from the OLD rootfs (still mounted,
# pre-mkfs) into the transaction store. The backup is a two-source merge:
# the rootfs partition mount is the overlay LOWER only, so apt-installed
# kernel modules that were copy-up'd are merged in from the userdata
# overlay upper dir. Whiteout char nodes are dropped (apt never needs them
# as deletions here).
#
# hook_post_apply restores the backup over the freshly extracted rootfs,
# replacing whatever the payload carried: the device keeps its running
# kernel's modules. The payload's dpkg status may name a different kernel
# version -- the familiar self-healing mismatch, realigned by the next
# apt kernel upgrade.
#
# The backup lives under ${OTA_DIR} and is removed with the payload at the
# cleanup step (after hook_post_apply), so nothing leaks.
#
# Sourced by 99-ota-apply into the orchestrator shell: expects log and the
# ROOT_MNT/USERDATA_MNT/OTA_DIR globals. Definition-only, no side effects.

km_modules_dir_in() { # $1=root mount -> prints usr/lib/modules or lib/modules
    if [ -d "$1/usr/lib/modules" ]; then
        printf '%s\n' "$1/usr/lib/modules"
    elif [ -d "$1/lib/modules" ]; then
        printf '%s\n' "$1/lib/modules"
    fi
}

km_backup_work() { # $1=src modules dir -> rc 0 backed up
    km_keep="${OTA_DIR}/.modules-keep"

    rm -rf "${km_keep}"
    mkdir -p "${km_keep}" || return 1

    # lower base (the direct partition mount)
    cp -a "$1/." "${km_keep}/" || return 1

    # overlay upper merge: apt-installed kernels live here, not in lower.
    # overlayroot layout: <userdata>/overlay{/usr,}/lib/modules
    for km_upper in "${USERDATA_MNT}/overlay/usr/lib/modules" "${USERDATA_MNT}/overlay/lib/modules"; do
        if [ -d "${km_upper}" ]; then
            cp -a "${km_upper}/." "${km_keep}/" &&
                log "keep-modules: merged overlay upper ${km_upper}"
            break
        fi
    done

    # drop overlay whiteout char nodes copied through
    find "${km_keep}" -type c -exec rm -f {} + 2>/dev/null

    log "keep-modules: backed up $(find "${km_keep}" -mindepth 1 -maxdepth 1 | wc -l) kernel version dir(s)"
    return 0
}

hook_pre_apply() {
    if [ ! -d "${ROOT_MNT}" ]; then
        log "keep-modules: ${ROOT_MNT} not mounted, nothing to keep"
        return 0
    fi

    km_src="$(km_modules_dir_in "${ROOT_MNT}")"
    if [ -z "${km_src}" ]; then
        log "keep-modules: no /lib/modules on the old rootfs, nothing to keep"
        return 0
    fi

    if ! km_backup_work "${km_src}"; then
        log "ERROR keep-modules: backup failed, abort OTA (rootfs untouched)"
        return 1
    fi

    # Literal extraction exclusion: GNU tar prepends TAR_OPTIONS to every
    # invocation, and extract_tar resolves the real GNU tar staged in the
    # initramfs -- so the built-in rootfs extract skips the modules tree
    # without any orchestrator change. If a busybox tar ever resolves
    # instead (TAR_OPTIONS ignored), the post_apply restore below still
    # replaces whatever was extracted: correctness never depends on this.
    TAR_OPTIONS="${TAR_OPTIONS:-} --exclude=./usr/lib/modules --exclude=./lib/modules"
    export TAR_OPTIONS
    log "keep-modules: TAR_OPTIONS exclusion armed for rootfs extract"
    return 0
}

hook_post_apply() {
    km_keep="${OTA_DIR}/.modules-keep"
    if [ ! -d "${km_keep}" ]; then
        log "keep-modules: no backup present, skip restore"
        return 0
    fi

    km_dst="$(km_modules_dir_in "${ROOT_MNT}")"
    if [ -z "${km_dst}" ]; then
        # payload carried no modules tree (excluded build): recreate at the
        # canonical usrmerge location, or plain /lib/modules as fallback
        if [ -L "${ROOT_MNT}/lib" ] || [ -d "${ROOT_MNT}/usr/lib" ]; then
            km_dst="${ROOT_MNT}/usr/lib/modules"
        else
            km_dst="${ROOT_MNT}/lib/modules"
        fi
    fi

    rm -rf "${km_dst}"
    mkdir -p "${km_dst}" || {
        log "ERROR keep-modules: cannot create ${km_dst}"
        return 1
    }
    if ! cp -a "${km_keep}/." "${km_dst}/"; then
        log "ERROR keep-modules: restore failed"
        return 1
    fi
    sync
    log "keep-modules: restored $(ls "${km_dst}" | wc -l) kernel version dir(s) -> ${km_dst}"
    return 0
}
