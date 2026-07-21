#
# Armbian OTA build extension entry point.
#
# Keep this file as the stable Armbian extension path. Implementation is split
# by common, A/B, and Recovery ownership; hook function names remain unchanged.
#

OTA_SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OTA_COMMON_ROOTFS="${OTA_SUPPORT_DIR}/common/rootfs"
readonly OTA_RECOVERY_ROOTFS="${OTA_SUPPORT_DIR}/recovery/rootfs"
readonly OTA_AB_ROOTFS="${OTA_SUPPORT_DIR}/ab/rootfs"

function ota_encrypted_rootfs_enabled() {
    [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]
}

function ota_secure_boot_encrypted_rootfs_enabled() {
    [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" ]] && ota_encrypted_rootfs_enabled
}

for ota_support_module in \
    common/build-hooks/image-naming \
    common/build-hooks/rootfs-install \
    recovery/build-hooks/partitions \
    recovery/build-hooks/runtime-install \
    ab/build-hooks/partitions \
    ab/build-hooks/overlayroot \
    ab/build-hooks/runtime-install \
    common/build-hooks/package-create
do
    # shellcheck source=/dev/null
    source "${OTA_SUPPORT_DIR}/${ota_support_module}.sh"
done

unset ota_support_module
