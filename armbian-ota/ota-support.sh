#
# Armbian OTA build extension entry point.
#
# Keep this file as the stable Armbian extension path. Implementation is split
# into build-hooks by build-time responsibility; hook function names remain unchanged.
#

OTA_SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OTA_RUNTIME_SRC="${OTA_SUPPORT_DIR}/runtime"
readonly OTA_RECOVERY_SRC="${OTA_SUPPORT_DIR}/recovery"
readonly OTA_AB_SRC="${OTA_SUPPORT_DIR}/ab"

function ota_encrypted_rootfs_enabled() {
    [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]
}

function ota_secure_boot_encrypted_rootfs_enabled() {
    [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" ]] && ota_encrypted_rootfs_enabled
}

for ota_support_module in \
    image-naming \
    ab-partitions \
    runtime-install \
    persist \
    package-create
do
    # shellcheck source=/dev/null
    source "${OTA_SUPPORT_DIR}/build-hooks/${ota_support_module}.sh"
done

unset ota_support_module
