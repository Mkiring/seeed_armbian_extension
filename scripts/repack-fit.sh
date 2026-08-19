#!/usr/bin/env bash
# repack-fit.sh — Re-sign boot.itb with a new dtbo list, without rerunning armbian build.
#
# Extracts base DTB / kernel / ramdisk / resource.img from an existing signed
# FIT, applies a new dtbo list to the base DTB, and re-signs a new boot.itb
# using the same RSA key that signed the original. The output is byte-for-byte
# bootable on the device after `dd` to the boot partition.
#
# Requires the RSA private key. Do NOT install this script on the device.

set -euo pipefail

readonly PROG_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly EXTENSION_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SECURE_BOOT_HOOK="${EXTENSION_ROOT}/rk_secure-disk-encryption/build-hooks/secure-boot-image.sh"
readonly DEFAULT_ITS_DIR="${EXTENSION_ROOT}/rk_secure-disk-encryption/u-boot/fit-kernel"

# ===== stubs for armbian-build helpers used by sourced functions =====
# The sourced functions (rk_secure_boot_apply_default_overlays etc.) call these
# three helpers from armbian-build's lib/. We provide minimal replacements so
# the script stays standalone — no need to source the whole armbian-build tree.
display_alert() {
    local tag="$1" msg="$2" level="${3:-info}"
    local prefix=".."
    case "${level}" in
        err|error) prefix="!!" ;;
        warn)      prefix="? " ;;
        info)      prefix=".." ;;
        debug)     prefix=". " ;;
    esac
    printf '%s [%s] %s\n' "${prefix}" "${tag}" "${msg}" >&2
}

exit_with_error() {
    local msg="$1" detail="${2:-}"
    printf '!! [ERR] %s: %s\n' "${msg}" "${detail}" >&2
    exit 1
}

# Sourced signing path treats full-secure-boot as fatal on signing failure.
# We always want fatal behavior — a stale/unsigned boot.itb is worse than none.
rk_full_secure_boot_enabled() { return 0; }

# ===== source reusable functions from secure-boot-image.sh =====
# These three are self-contained enough to reuse:
#   - rk_secure_boot_apply_default_overlays  (fdtoverlay)
#   - rk_secure_boot_patch_dtb_bootargs      (fdtput /chosen/bootargs)
#   - rk_secure_boot_run_secondary_fit_signing (mkimage -r)
# shellcheck disable=SC1090
source "${SECURE_BOOT_HOOK}"

# ===== defaults =====
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
CACHE_DIR="${HOME}/.cache/repack-fit"
NO_CACHE=0
KEEP_WORKDIR=0
BOOTARGS_OVERRIDE=""
ITS_TEMPLATE_OVERRIDE=""
WORKDIR_OVERRIDE=""
DOCKER_IMAGE=""

# ===== state (populated by parse_args) =====
SOURCE_BOOT_ITB=""
DTBO_LIST=""
LINUX_SOURCE=""
UBOOT_DIR=""
KEYS_SOURCE_DIR=""
BOOT_SOC=""
OUTPUT_PATH=""
ITS_TEMPLATE=""
WORKDIR=""
CACHE_TCDIR_VER=""

usage() {
    cat <<EOF
Usage: ${PROG_NAME} --source-boot-itb <path> --dtbo-list "n1 n2 ..." \\
    --linux-source <path> --u-boot-dir <path> --keys-source-dir <path> \\
    --boot-soc {rk3576|rk3588} --output <path> [options]

Required:
  --source-boot-itb PATH      Existing signed boot.itb to extract artifacts from
  --dtbo-list "NAMES"         Space-separated dtbo names (no .dtbo suffix)
  --linux-source PATH         linux-rockchip source root (for dtbo compilation)
  --u-boot-dir PATH           U-Boot worktree (provides tools/mkimage, tools/dumpimage, tools/fit_check_sign)
  --keys-source-dir PATH      Directory containing private_key.pem (+ optional dev.crt, public_key.pem)
  --boot-soc SOC              rk3576 or rk3588 (selects ITS template + load addresses)
  --output PATH               Where to write the new boot.itb

Optional:
  --cross-compile PREFIX      Default: aarch64-linux-gnu-
  --its-template PATH         Override default ITS template for --boot-soc
  --cache-dir PATH            Default: ~/.cache/repack-fit
  --no-cache                  Force dtbo recompilation
  --bootargs ARGS             Override /chosen/bootargs (default: extracted from source boot.itb)
  --workdir PATH              Use this workdir instead of mktemp -d
  --docker-image IMAGE        Sign + verify inside this docker container
                              (e.g. armbian.local.only/armbian-build:<tag>).
                              Required unless running as root: the U-Boot
                              worktree is root-owned AND the host OpenSSL
                              signs PSS with the wrong salt length.
  --keep-workdir              Don't delete workdir on exit (debug)
  -h, --help                  Show this help
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source-boot-itb)    SOURCE_BOOT_ITB="$2"; shift 2 ;;
            --dtbo-list)          DTBO_LIST="$2"; shift 2 ;;
            --linux-source)       LINUX_SOURCE="$2"; shift 2 ;;
            --u-boot-dir)         UBOOT_DIR="$2"; shift 2 ;;
            --keys-source-dir)    KEYS_SOURCE_DIR="$2"; shift 2 ;;
            --boot-soc)           BOOT_SOC="$2"; shift 2 ;;
            --output)             OUTPUT_PATH="$2"; shift 2 ;;
            --cross-compile)      CROSS_COMPILE="$2"; shift 2 ;;
            --its-template)       ITS_TEMPLATE_OVERRIDE="$2"; shift 2 ;;
            --cache-dir)          CACHE_DIR="$2"; shift 2 ;;
            --no-cache)           NO_CACHE=1; shift ;;
            --bootargs)           BOOTARGS_OVERRIDE="$2"; shift 2 ;;
            --workdir)            WORKDIR_OVERRIDE="$2"; shift 2 ;;
            --docker-image)       DOCKER_IMAGE="$2"; shift 2 ;;
            --keep-workdir)       KEEP_WORKDIR=1; shift ;;
            -h|--help)            usage; exit 0 ;;
            *)                    echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
    done

    local missing=()
    [[ -n "${SOURCE_BOOT_ITB}" ]]    || missing+=(--source-boot-itb)
    [[ -n "${DTBO_LIST}" ]]          || missing+=(--dtbo-list)
    [[ -n "${LINUX_SOURCE}" ]]       || missing+=(--linux-source)
    [[ -n "${UBOOT_DIR}" ]]          || missing+=(--u-boot-dir)
    [[ -n "${KEYS_SOURCE_DIR}" ]]    || missing+=(--keys-source-dir)
    [[ -n "${BOOT_SOC}" ]]           || missing+=(--boot-soc)
    [[ -n "${OUTPUT_PATH}" ]]        || missing+=(--output)
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing required: ${missing[*]}" >&2
        echo >&2
        usage >&2
        exit 2
    fi

    case "${BOOT_SOC}" in
        rk3576|rk3588) ;;
        *)
            echo "Invalid --boot-soc '${BOOT_SOC}'. Must be rk3576 or rk3588." >&2
            exit 2
            ;;
    esac

    if [[ -n "${ITS_TEMPLATE_OVERRIDE}" ]]; then
        ITS_TEMPLATE="${ITS_TEMPLATE_OVERRIDE}"
    else
        ITS_TEMPLATE="${DEFAULT_ITS_DIR}/${BOOT_SOC}_fit_kernel.its"
    fi

    # Normalize to absolute paths: later stages cd into a temp workdir, and any
    # user-supplied ../path would silently resolve against the wrong directory.
    local p
    for p in SOURCE_BOOT_ITB LINUX_SOURCE UBOOT_DIR KEYS_SOURCE_DIR ITS_TEMPLATE; do
        declare -g "${p}=$(readlink -m "${!p}")"
    done
    OUTPUT_PATH="$(readlink -m "${OUTPUT_PATH}")"
}

check_required_tools() {
    local -a missing=()
    local tool

    # The signing step writes ${UBOOT_DIR}/fit/boot.itb — the armbian-build
    # cache is root-owned, so an unprivileged run fails halfway through.
    # Fail early with a clear hint instead. Docker mode bypasses this: the
    # write happens inside the container (docker daemon is root).
    if [[ -z "${DOCKER_IMAGE}" && ! -w "${UBOOT_DIR}" ]]; then
        cat >&2 <<EOF
!! [ERR] No write permission in --u-boot-dir: ${UBOOT_DIR}

The signing step must write ${UBOOT_DIR}/fit/boot.itb and may need to
rebuild tools/mkimage. The armbian-build cache is typically root-owned.

Either rerun with sudo, or use --docker-image to sign inside the armbian
build container (recommended — the container OpenSSL signs PSS with the
salt length this U-Boot's fit_check_sign expects; the host OpenSSL 3.x
default does not, and signatures made on the host fail verification).
EOF
        exit 1
    fi

    for tool in fdtoverlay fdtput fdtget openssl make install; do
        command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
    done

    # u-boot tools live in ${UBOOT_DIR}/tools/
    local -a uboot_tools=("mkimage" "dumpimage" "fit_check_sign")
    for tool in "${uboot_tools[@]}"; do
        local path="${UBOOT_DIR}/tools/${tool}"
        if [[ ! -x "${path}" ]]; then
            # Try PATH as fallback (some distros package these)
            if ! command -v "${tool}" >/dev/null 2>&1; then
                missing+=("${path}")
            fi
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        cat >&2 <<EOF
Missing required tools:
$(printf '  - %s\n' "${missing[@]}")

Install hints:
  fdtoverlay/fdtput/fdtget : apt install device-tree-compiler
  openssl/install/make     : standard build-essential
  mkimage/dumpimage/fit_check_sign : build u-boot, or point --u-boot-dir at its worktree

The u-boot tools must live in <u-boot-dir>/tools/. If they're elsewhere on PATH,
symlink them or extend this script.
EOF
        exit 1
    fi
}

resolve_tool() {
    # Prefer ${UBOOT_DIR}/tools/<tool>, fall back to PATH lookup.
    local tool="$1"
    local path="${UBOOT_DIR}/tools/${tool}"
    if [[ -x "${path}" ]]; then
        printf '%s' "${path}"
    else
        printf '%s' "$(command -v "${tool}")"
    fi
}

extract_source_artifacts() {
    local work="$1"
    local dumpimage
    dumpimage="$(resolve_tool dumpimage)"

    display_alert "repack-fit" "Extracting artifacts from ${SOURCE_BOOT_ITB}" "info"

    [[ -f "${SOURCE_BOOT_ITB}" ]] ||
        exit_with_error "Source boot.itb not found" "${SOURCE_BOOT_ITB}"

    # List first — also validates the FIT is parseable.
    "${dumpimage}" -l "${SOURCE_BOOT_ITB}" >/dev/null 2>&1 ||
        exit_with_error "Source boot.itb is not a valid FIT image" "${SOURCE_BOOT_ITB}"

    # ITS node order: fdt, kernel, ramdisk, resource (matches rkXXXX_fit_kernel.its).
    # dumpimage -p is zero-based. Always pass -T flat_dt: this dumpimage build only
    # registers an extraction handler for flat_dt (-T kernel/ramdisk/multi exit 255),
    # while -p alone selects which image node is actually extracted.
    local node
    local -a nodes=(
        "0:base.dtb:fdt"
        "1:Image:kernel"
        "2:uInitrd:ramdisk"
        "3:resource.img:resource"
    )
    for node in "${nodes[@]}"; do
        local pos="${node%%:*}"
        local rest="${node#*:}"
        local fname="${rest%%:*}"
        local label="${rest##*:}"
        "${dumpimage}" -i "${SOURCE_BOOT_ITB}" -T flat_dt -p "${pos}" -o "${work}/${fname}" "${SOURCE_BOOT_ITB}" >/dev/null ||
            exit_with_error "Failed to extract ${label} image" "-p ${pos}"
    done

    [[ -s "${work}/base.dtb" && -s "${work}/Image" && -s "${work}/uInitrd" ]] ||
        exit_with_error "Extraction produced empty files" "${work}"

    # resource.img may legitimately be a zero-byte placeholder; warn if so.
    if [[ ! -s "${work}/resource.img" ]]; then
        display_alert "repack-fit" "resource.img is empty (will be embedded as zero-length)" "warn"
    fi
}

prepare_keys_workdir() {
    local work="$1"
    local keys_work="${work}/keys"

    mkdir -p "${keys_work}"

    [[ -f "${KEYS_SOURCE_DIR}/private_key.pem" ]] ||
        exit_with_error "Private key missing" "${KEYS_SOURCE_DIR}/private_key.pem"

    display_alert "repack-fit" "Staging signing keys from ${KEYS_SOURCE_DIR}" "info"

    install -m 0600 "${KEYS_SOURCE_DIR}/private_key.pem" "${keys_work}/private_key.pem"

    if [[ -f "${KEYS_SOURCE_DIR}/public_key.pem" ]]; then
        install -m 0644 "${KEYS_SOURCE_DIR}/public_key.pem" "${keys_work}/public_key.pem"
    else
        openssl pkey -in "${keys_work}/private_key.pem" -pubout -out "${keys_work}/public_key.pem"
        chmod 0644 "${keys_work}/public_key.pem"
    fi

    if [[ -f "${KEYS_SOURCE_DIR}/dev.crt" ]]; then
        install -m 0644 "${KEYS_SOURCE_DIR}/dev.crt" "${keys_work}/dev.crt"
    else
        # Self-signed cert is what armbian-build's secure-boot-uboot.sh:449 does.
        openssl req -batch -new -x509 -key "${keys_work}/private_key.pem" \
            -out "${keys_work}/dev.crt" -subj "/CN=Armbian FIT Key/" >/dev/null 2>&1 ||
            exit_with_error "Failed to generate dev.crt" "openssl req"
        chmod 0644 "${keys_work}/dev.crt"
    fi

    # mkimage -k expects <key-name-hint>.key and <key-name-hint>.crt.
    # ITS template declares key-name-hint = "dev".
    ln -sf private_key.pem "${keys_work}/dev.key"
    ln -sf public_key.pem  "${keys_work}/dev.pubkey"

    printf '%s' "${keys_work}"
}

# Cache layout: <cache-dir>/<dtbo-name>.<mtime-hash>.dtbo
# Hash combines the .dts (or prebuilt .dtbo) mtime so source edits invalidate
# the cache automatically.
compute_cache_key() {
    local dtbo_name="$1"
    local overlay_dir="${LINUX_SOURCE}/arch/arm64/boot/dts/rockchip/overlay"
    local dts_src="${overlay_dir}/${dtbo_name}.dts"
    local dtbo_prebuilt="${overlay_dir}/${dtbo_name}.dtbo"
    local src="${dts_src}"

    [[ -f "${src}" ]] || src="${dtbo_prebuilt}"
    [[ -f "${src}" ]] ||
        exit_with_error "dtbo not found" "${dts_src} / ${dtbo_prebuilt}"

    local mtime hash cache_key
    mtime=$(stat -c '%Y %s' "${src}")
    hash=$(printf '%s|%s' "${dtbo_name}" "${mtime}" | sha256sum | cut -c1-16)
    cache_key="${dtbo_name}.${hash}"
    printf '%s' "${cache_key}"
}

compile_dtbo_list() {
    local overlay_out_dir="$1"
    mkdir -p "${overlay_out_dir}"

    if [[ "${NO_CACHE}" -eq 0 ]]; then
        mkdir -p "${CACHE_DIR}"
    fi

    local dtbo_name dts_src dtbo_prebuilt cache_key cached_path out_path
    local overlay_dir="${LINUX_SOURCE}/arch/arm64/boot/dts/rockchip/overlay"
    for dtbo_name in ${DTBO_LIST}; do
        dts_src="${overlay_dir}/${dtbo_name}.dts"
        dtbo_prebuilt="${overlay_dir}/${dtbo_name}.dtbo"
        if [[ ! -f "${dts_src}" && ! -f "${dtbo_prebuilt}" ]]; then
            local available
            available=$(ls "${overlay_dir}/" 2>/dev/null \
                        | grep -E "^recomputer-${BOOT_SOC}-devkit-.*\.dtbo\$" \
                        | sed 's/\.dtbo$//' \
                        | tr '\n' ' ')
            exit_with_error "dtbo not found: ${dtbo_name}" \
                "available recomputer-${BOOT_SOC}-devkit-* overlays: ${available:-<none>}"
        fi

        out_path="${overlay_out_dir}/${dtbo_name}.dtbo"
        cache_key="$(compute_cache_key "${dtbo_name}")"
        cached_path="${CACHE_DIR}/${cache_key}.dtbo"

        if [[ "${NO_CACHE}" -eq 0 && -f "${cached_path}" ]]; then
            display_alert "repack-fit" "cache hit: ${dtbo_name}" "info"
            cp "${cached_path}" "${out_path}"
            continue
        fi

        # The kernel worktree usually already carries the built .dtbo from a
        # prior armbian-build run. Reuse it when it is not older than its .dts.
        if [[ -f "${dtbo_prebuilt}" && ( ! -f "${dts_src}" || "${dtbo_prebuilt}" -nt "${dts_src}" ) ]]; then
            display_alert "repack-fit" "using prebuilt dtbo: ${dtbo_name}" "info"
            cp "${dtbo_prebuilt}" "${out_path}"
        else
            display_alert "repack-fit" "compiling dtbo: ${dtbo_name}" "info"

            # Target is relative to arch/arm64/boot/dts/ — the kbuild dts
            # rule prepends that prefix itself; passing the full path makes
            # it doubled and the rule misses.
            local make_err
            if ! make_err=$(cd "${LINUX_SOURCE}" && \
                    make ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" \
                    "rockchip/overlay/${dtbo_name}.dtbo" 2>&1); then
                printf '%s\n' "${make_err}" >&2
                exit_with_error "dtbo compilation failed" "${dtbo_name}"
            fi

            [[ -f "${dtbo_prebuilt}" ]] ||
                exit_with_error "dtbo build produced no output" "${dtbo_name}.dtbo"

            cp "${dtbo_prebuilt}" "${out_path}"
        fi

        if [[ "${NO_CACHE}" -eq 0 ]]; then
            # Clean stale cache entries for this dtbo name before writing the new one.
            rm -f "${CACHE_DIR}/${dtbo_name}."*.dtbo 2>/dev/null || true
            cp "${out_path}" "${cached_path}"
        fi
    done
}

apply_overlays() {
    local work="$1"
    local overlay_dir="${work}/overlays"

    # rk_secure_boot_apply_default_overlays reads DEFAULT_OVERLAYS global.
    # Mirror the armbian-build convention so we can reuse the function as-is.
    export DEFAULT_OVERLAYS="${DTBO_LIST}"

    display_alert "repack-fit" "Applying overlays: ${DEFAULT_OVERLAYS}" "info"
    rk_secure_boot_apply_default_overlays "${work}/base.dtb" "${overlay_dir}"
}

inject_bootargs() {
    local work="$1"
    local bootargs="${BOOTARGS_OVERRIDE}"

    if [[ -z "${bootargs}" ]]; then
        # Preserve existing /chosen/bootargs from the source boot.itb's base DTB.
        # fdtget returns non-zero if /chosen or bootargs is absent — that's fine,
        # we just pass an empty string through (fdtput -c ensures /chosen exists).
        bootargs="$(fdtget -t s "${work}/base.dtb" /chosen bootargs 2>/dev/null || true)"
        if [[ -z "${bootargs}" ]]; then
            display_alert "repack-fit" "No /chosen/bootargs in source base DTB; leaving bootargs unset" "warn"
            return 0
        fi
        display_alert "repack-fit" "Inherited bootargs from source: ${bootargs}" "info"
    else
        display_alert "repack-fit" "Using override bootargs: ${bootargs}" "info"
    fi

    rk_secure_boot_patch_dtb_bootargs "${work}/base.dtb" "${bootargs}"
}

substitute_its_template() {
    local work="$1"

    [[ -f "${ITS_TEMPLATE}" ]] ||
        exit_with_error "ITS template not found" "${ITS_TEMPLATE}"

    display_alert "repack-fit" "Using ITS template: ${ITS_TEMPLATE}" "info"

    cp -f "${ITS_TEMPLATE}" "${work}/boot-final.its"
    sed -i \
        -e "s|@KERNEL_DTB@|${work}/base.dtb|g" \
        -e "s|@KERNEL_IMG@|${work}/Image|g" \
        -e "s|@RAMDISK_IMG@|${work}/uInitrd|g" \
        -e "s|@RESOURCE_IMG@|${work}/resource.img|g" \
        "${work}/boot-final.its"
}

initial_mkimage() {
    local work="$1"
    local mkimage
    mkimage="$(resolve_tool mkimage)"

    display_alert "repack-fit" "Generating unsigned boot-final.img" "info"
    (
        cd "${work}" || exit 1
        "${mkimage}" -f boot-final.its -E -p 0x800 boot-final.img
    ) || exit_with_error "mkimage (initial) failed" "${work}/boot-final.its"
}

secondary_signing() {
    local work="$1"
    local fit_padding="0x1000"

    if grep -q '^CONFIG_FIT_ENABLE_RSA4096_SUPPORT=y' "${UBOOT_DIR}/.config" 2>/dev/null; then
        fit_padding="0x1200"
    fi

    if [[ -n "${DOCKER_IMAGE}" ]]; then
        # Sign inside the armbian build container. Reason: this U-Boot fork's
        # rsa-sign.c never sets a PSS salt length, so mkimage follows the
        # OpenSSL default. The container's OpenSSL signs with salt = max
        # (222 for RSA2048+sha256), matching the hardcoded expectation in
        # rsa-verify.c padding_pss_verify. Host OpenSSL 3.x defaults to
        # salt = hash length (32) — such signatures always fail verification.
        display_alert "repack-fit" "Signing FIT in docker: ${DOCKER_IMAGE}" "info"
        if ! docker run --rm \
                -v "${work}:${work}" \
                -v "${UBOOT_DIR}:${UBOOT_DIR}" \
                "${DOCKER_IMAGE}" bash -c "
                    set -e
                    cd '${UBOOT_DIR}'
                    mkdir -p fit
                    ./tools/mkimage -f '${work}/boot-final.its' -k keys/ -E -p ${fit_padding} -r fit/boot.itb
                "; then
            exit_with_error "docker signing failed" "${DOCKER_IMAGE}"
        fi
        return 0
    fi

    # rk_secure_boot_run_secondary_fit_signing expects to be called from the
    # u-boot tree (uses ${uboot_dir}/tools/mkimage and ${uboot_dir}/u-boot.dtb).
    # It writes the signed FIT to ${uboot_dir}/fit/boot.itb.
    #
    # This u-boot's mkimage exits 1 on `-h` (unknown option, usage still
    # printed). Under `set -o pipefail` the `mkimage -h | grep` guards inside
    # the sourced function inherit that rc and falsely report "lacks FIT
    # signature support". Disable pipefail for the duration of the call.
    display_alert "repack-fit" "Signing FIT on host (RSA, key-name-hint=dev)" "info"
    set +o pipefail
    rk_secure_boot_run_secondary_fit_signing "${work}" "${UBOOT_DIR}"
    local rc=$?
    set -o pipefail
    return "${rc}"
}

fit_check_sign() {
    local check_tool
    check_tool="$(resolve_tool fit_check_sign)"

    if [[ -n "${DOCKER_IMAGE}" ]]; then
        display_alert "repack-fit" "Verifying signature in docker" "info"
        if ! docker run --rm \
                -v "${UBOOT_DIR}:${UBOOT_DIR}" \
                "${DOCKER_IMAGE}" bash -c "
                    set -e
                    cd '${UBOOT_DIR}'
                    ./tools/fit_check_sign -f fit/boot.itb -k u-boot.dtb
                " >/dev/null; then
            cat >&2 <<'EOF'

Signature verification failed. Likely causes:
  1. The keys in --u-boot-dir/keys or --keys-source-dir do not match the
     public key embedded in u-boot.dtb (this U-Boot was built with a
     different key).
  2. The docker image's OpenSSL signs with an unexpected PSS salt length.
EOF
            exit 1
        fi
        display_alert "repack-fit" "Signature check OK (in container)" "info"
        return 0
    fi

    if [[ ! -x "${check_tool}" ]]; then
        display_alert "repack-fit" "fit_check_sign not available, skipping verification" "warn"
        return 0
    fi

    local signed_itb="${UBOOT_DIR}/fit/boot.itb"
    local uboot_dtb="${UBOOT_DIR}/u-boot.dtb"

    [[ -f "${signed_itb}" ]] ||
        exit_with_error "Signed boot.itb missing after signing" "${signed_itb}"
    [[ -f "${uboot_dtb}" ]] ||
        exit_with_error "u-boot.dtb missing (needed for signature verification)" "${uboot_dtb}"

    display_alert "repack-fit" "Verifying signature with fit_check_sign" "info"
    if ! "${check_tool}" -f "${signed_itb}" -k "${uboot_dtb}" 2>&1; then
        cat >&2 <<EOF

Signature verification failed. Likely causes:
  1. The private_key.pem in --keys-source-dir does not match the public key
     embedded in u-boot.dtb (i.e. this U-Boot was built with a different key).
  2. u-boot.dtb was rebuilt after the key was rotated.

Resolution: obtain the matching private key, or rebuild U-Boot from the same
source with --keys-source-dir pointing at this key.
EOF
        exit 1
    fi
}

emit_output() {
    local signed_itb="${UBOOT_DIR}/fit/boot.itb"

    [[ -f "${signed_itb}" ]] ||
        exit_with_error "Signed boot.itb not where expected" "${signed_itb}"

    cp -f "${signed_itb}" "${OUTPUT_PATH}" ||
        exit_with_error "Failed to write output" "${OUTPUT_PATH}"

    local size_kb
    size_kb=$(( $(stat -c%s "${OUTPUT_PATH}") / 1024 ))
    display_alert "repack-fit" "Wrote ${OUTPUT_PATH} (${size_kb} KB)" "info"
}

cleanup_workdir() {
    if [[ "${KEEP_WORKDIR}" -eq 1 ]]; then
        display_alert "repack-fit" "Keeping workdir: ${WORKDIR}" "info"
        return
    fi
    # Always remove keys first to minimize exposure window.
    rm -rf "${WORKDIR}/keys" 2>/dev/null || true
    rm -rf "${WORKDIR}" 2>/dev/null || true
}

main() {
    parse_args "$@"
    check_required_tools

    if [[ -n "${WORKDIR_OVERRIDE}" ]]; then
        WORKDIR="${WORKDIR_OVERRIDE}"
        mkdir -p "${WORKDIR}"
    else
        WORKDIR="$(mktemp -d)"
    fi

    # All artifacts land under WORKDIR. overlays/ holds compiled dtbos for
    # rk_secure_boot_apply_default_overlays to pick up (it expects
    # <overlay_dir>/<name>.dtbo).
    mkdir -p "${WORKDIR}/overlays"

    trap cleanup_workdir EXIT

    extract_source_artifacts "${WORKDIR}"
    compile_dtbo_list "${WORKDIR}/overlays"
    apply_overlays "${WORKDIR}"
    inject_bootargs "${WORKDIR}"
    substitute_its_template "${WORKDIR}"
    initial_mkimage "${WORKDIR}"
    secondary_signing "${WORKDIR}"
    fit_check_sign
    emit_output

    display_alert "repack-fit" "Done. Flash with: dd if=${OUTPUT_PATH} of=/dev/mmcblkXp1 conv=fsync" "info"
}

main "$@"
