#!/bin/sh

ota_state_set_key() {
    state_file="$1"
    key="$2"
    value="$3"

    if grep -q -E "^${key}=" "${state_file}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${state_file}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${state_file}"
    fi
}

ota_state_write_file() {
    state_file="$1"
    state_dir="${state_file%/*}"

    mkdir -p "${state_dir}" || return 1
    cat > "${state_file}" <<'EOF' || return 1
# Armbian OTA runtime state
OTA_MODE=
STATUS=idle
PACKAGE_PATH=
CURRENT_SLOT=
TARGET_SLOT=
START_TIME=
COMPLETE_TIME=
EOF

    ota_state_set_key "${state_file}" OTA_MODE "${OTA_STATE_MODE:-}" || return 1
    ota_state_set_key "${state_file}" STATUS "${OTA_STATE_STATUS:-idle}" || return 1
    ota_state_set_key "${state_file}" PACKAGE_PATH "${OTA_STATE_PACKAGE_PATH:-}" || return 1
    ota_state_set_key "${state_file}" CURRENT_SLOT "${OTA_STATE_CURRENT_SLOT:-}" || return 1
    ota_state_set_key "${state_file}" TARGET_SLOT "${OTA_STATE_TARGET_SLOT:-}" || return 1
    ota_state_set_key "${state_file}" START_TIME "${OTA_STATE_START_TIME:-}" || return 1
    ota_state_set_key "${state_file}" COMPLETE_TIME "${OTA_STATE_COMPLETE_TIME:-}" || return 1
}
