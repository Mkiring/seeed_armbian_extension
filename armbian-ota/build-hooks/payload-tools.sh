#
# Payload Tool Helpers
#

function ota_write_payload_tools_readme() {
    local payload_tools_dir="$1"

    cat > "${payload_tools_dir}/README_INSTALL.txt" << 'EOF'
Armbian OTA Runtime Tools

This payload contains OTA runtime scripts for fallback/offline installation.

If firmware was built with OTA enabled:
- AB firmware (`AB_PART_OTA=yes`) already includes AB OTA runtime/tools.
- Recovery firmware (`OTA_ENABLE=yes`, no `AB_PART_OTA`) already includes Recovery OTA runtime/tools.

In those cases, you only need to copy the OTA package and run `armbian-ota start <ota-package.tar.gz>`.

Typical usage:
1) If your firmware does not include OTA runtime, copy ota_tools/ to target board.
2) Install runtime CLI and libraries manually (as root), for example:
   cp -a runtime/bin/armbian-ota /usr/sbin/armbian-ota
   chmod +x /usr/sbin/armbian-ota
   mkdir -p /usr/share/armbian-ota
   cp -a runtime/lib/common.sh /usr/share/armbian-ota/common.sh
   cp -a runtime/lib/state.sh /usr/share/armbian-ota/state.sh
   cp -a runtime/lib/persist.sh /usr/share/armbian-ota/persist.sh
   cp -a runtime/lib/preserve.sh /usr/share/armbian-ota/preserve.sh
   mkdir -p /etc/armbian-ota
   cp -a runtime/policy/ota-state.env.template /etc/armbian-ota/ota-state.env.template
   if [ -f /etc/armbian-ota/persist-map.txt ]; then
       cp -a runtime/policy/persist-map.txt /etc/armbian-ota/persist-map.txt.default
   else
       cp -a runtime/policy/persist-map.txt /etc/armbian-ota/persist-map.txt
   fi
   if [ -f /etc/armbian-ota/preserve-list.txt ]; then
       cp -a runtime/policy/preserve-list.txt /etc/armbian-ota/preserve-list.txt.default
   else
       cp -a runtime/policy/preserve-list.txt /etc/armbian-ota/preserve-list.txt
   fi
   cp -a ab/backend.sh /usr/share/armbian-ota/backend-ab.sh
   cp -a recovery/backend.sh /usr/share/armbian-ota/backend-recovery.sh
   mkdir -p /usr/share/armbian-ota/recovery
   cp -a recovery/. /usr/share/armbian-ota/recovery/

3) Trigger OTA:
   armbian-ota start <ota-package.tar.gz>
EOF
}

function ota_copy_payload_tools() {
    local ota_temp_dir="$1"
    local ota_ext_dir
    ota_ext_dir="${OTA_SUPPORT_DIR}"
    local runtime_src="${ota_ext_dir}/runtime"
    local ab_src="${ota_ext_dir}/ab"
    local recovery_src="${ota_ext_dir}/recovery"
    local payload_tools_dir="${ota_temp_dir}/ota_tools"

    mkdir -p "${payload_tools_dir}"

    if [[ -d "${runtime_src}" ]]; then
        mkdir -p "${payload_tools_dir}/runtime"
        cp -a "${runtime_src}/." "${payload_tools_dir}/runtime/" || {
            display_alert "OTA payload" "Failed to copy runtime tools into payload" "err"
            return 1
        }
    else
        display_alert "OTA payload" "runtime source dir not found: ${runtime_src}" "warn"
    fi

    if [[ -d "${ab_src}" ]]; then
        mkdir -p "${payload_tools_dir}/ab"
        cp -a "${ab_src}/lib" "${payload_tools_dir}/ab/" 2>/dev/null || true
        cp -a "${ab_src}/runtime" "${payload_tools_dir}/ab/" 2>/dev/null || true
        cp -a "${ab_src}/systemd" "${payload_tools_dir}/ab/" 2>/dev/null || true
    fi

    if [[ -d "${recovery_src}" ]]; then
        mkdir -p "${payload_tools_dir}/recovery"
        cp -a "${recovery_src}/bin" "${payload_tools_dir}/recovery/" 2>/dev/null || true
        cp -a "${recovery_src}/runtime" "${payload_tools_dir}/recovery/" 2>/dev/null || true
        cp -a "${recovery_src}/initramfs_hooks" "${payload_tools_dir}/recovery/" 2>/dev/null || true
    fi

    ota_write_payload_tools_readme "${payload_tools_dir}"
}
