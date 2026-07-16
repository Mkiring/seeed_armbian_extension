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
