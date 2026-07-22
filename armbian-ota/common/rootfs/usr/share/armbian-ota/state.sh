#!/bin/sh

OTA_STATE_DIR="${OTA_STATE_DIR:-/var/lib/armbian-ota}"
OTA_STATE_FILE="${OTA_STATE_FILE:-${OTA_STATE_DIR}/ota-state.env}"

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

state_init() {
    mkdir -p "${OTA_STATE_DIR}" 2>/dev/null || return 1
    [ -f "${OTA_STATE_FILE}" ] && return 0

    (
        OTA_STATE_STATUS=idle
        ota_state_write_file "${OTA_STATE_FILE}"
    )
}

state_get() {
    local key="$1"

    if [ -f "${OTA_STATE_FILE}" ]; then
        grep -E "^${key}=" "${OTA_STATE_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2-
    fi
}

state_set() {
    local key="$1"
    local value="$2"

    state_init || return 1
    ota_state_set_key "${OTA_STATE_FILE}" "${key}" "${value}"
}

state_mark_mode() {
    state_set "OTA_MODE" "$1"
}

state_mark_status() {
    state_set "STATUS" "$1"
}

state_mark_prepared() {
    local mode="$1"
    local status="$2"
    local package_path="$3"
    local current_slot="${4:-}"
    local target_slot="${5:-}"

    state_init || return 1
    state_mark_mode "${mode}" || return 1
    state_mark_status "${status}" || return 1
    state_set "PACKAGE_PATH" "$(basename "${package_path}")" || return 1
    state_set "CURRENT_SLOT" "${current_slot}" || return 1
    state_set "TARGET_SLOT" "${target_slot}" || return 1
    state_set "START_TIME" "$(date -Iseconds)" || return 1
    state_set "COMPLETE_TIME" "" || return 1
}

state_mark_completed() {
    local mode="$1"
    local status="$2"
    local current_slot="${3:-}"
    local target_slot="${4:-}"

    state_init || return 1
    state_mark_mode "${mode}" || return 1
    state_mark_status "${status}" || return 1
    state_set "CURRENT_SLOT" "${current_slot}" || return 1
    state_set "TARGET_SLOT" "${target_slot}" || return 1
    state_set "COMPLETE_TIME" "$(date -Iseconds)" || return 1
}
