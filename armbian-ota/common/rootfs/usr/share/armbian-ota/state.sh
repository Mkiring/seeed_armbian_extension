#!/bin/sh

OTA_STATE_DIR="${OTA_STATE_DIR:-/var/lib/armbian-ota}"
OTA_STATE_FILE="${OTA_STATE_FILE:-${OTA_STATE_DIR}/ota-state.env}"

# Shared retry budget for recovery-mode apply and rollback attempts
# (design: recovery-ota-backup-rollback-design.md section 6.2).
OTA_MAX_RETRY="${OTA_MAX_RETRY:-3}"

ota_state_set_key() {
    local state_file="$1"
    local key="$2"
    local value="$3"
    local tmp_file

    if grep -q -E "^${key}=" "${state_file}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${state_file}"
    else
        # Atomic append: a bare >> can leave a half-written line on power
        # loss, and the reader then treats the key as missing (fail-open in
        # a fail-closed design). Rewrite through a temp file and rename.
        tmp_file="${state_file}.tmp"
        if ! { cat "${state_file}" 2>/dev/null; printf '%s=%s\n' "${key}" "${value}"; } > "${tmp_file}"; then
            rm -f "${tmp_file}" 2>/dev/null
            return 1
        fi
        if ! mv "${tmp_file}" "${state_file}"; then
            rm -f "${tmp_file}" 2>/dev/null
            return 1
        fi
    fi
}

# Reader companion to ota_state_set_key for an explicit state file.
ota_state_get_key() {
    grep -E "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d'=' -f2-
}

ota_state_write_file() {
    # local is load-bearing: set_key reuses these names, and a clobbered
    # state_file would turn the final rename into mv tmp tmp.
    local state_file="$1"
    local state_dir="${state_file%/*}"
    local tmp_file="${state_file}.tmp"

    mkdir -p "${state_dir}" || return 1
    # Write through a temp file and rename: a power cut mid-write must
    # never leave a truncated state that readers would parse as "no state"
    # and fail open. The original stays intact until the rename lands.
    cat > "${tmp_file}" <<'EOF' || { rm -f "${tmp_file}" 2>/dev/null; return 1; }
# Armbian OTA runtime state
OTA_MODE=
STATUS=idle
PACKAGE_PATH=
CURRENT_SLOT=
TARGET_SLOT=
START_TIME=
COMPLETE_TIME=
RETRY_COUNT=0
ERROR_MSG=
BACKUP_PARTIAL=0
EOF

    ota_state_set_key "${tmp_file}" OTA_MODE "${OTA_STATE_MODE:-}" || { rm -f "${tmp_file}" 2>/dev/null; return 1; }
    ota_state_set_key "${tmp_file}" STATUS "${OTA_STATE_STATUS:-idle}" || { rm -f "${tmp_file}" 2>/dev/null; return 1; }
    ota_state_set_key "${tmp_file}" PACKAGE_PATH "${OTA_STATE_PACKAGE_PATH:-}" || { rm -f "${tmp_file}" 2>/dev/null; return 1; }
    ota_state_set_key "${tmp_file}" CURRENT_SLOT "${OTA_STATE_CURRENT_SLOT:-}" || { rm -f "${tmp_file}" 2>/dev/null; return 1; }
    ota_state_set_key "${tmp_file}" TARGET_SLOT "${OTA_STATE_TARGET_SLOT:-}" || { rm -f "${tmp_file}" 2>/dev/null; return 1; }
    ota_state_set_key "${tmp_file}" START_TIME "${OTA_STATE_START_TIME:-}" || { rm -f "${tmp_file}" 2>/dev/null; return 1; }
    ota_state_set_key "${tmp_file}" COMPLETE_TIME "${OTA_STATE_COMPLETE_TIME:-}" || { rm -f "${tmp_file}" 2>/dev/null; return 1; }
    ota_state_set_key "${tmp_file}" RETRY_COUNT "${OTA_STATE_RETRY_COUNT:-0}" || { rm -f "${tmp_file}" 2>/dev/null; return 1; }
    ota_state_set_key "${tmp_file}" ERROR_MSG "${OTA_STATE_ERROR_MSG:-}" || { rm -f "${tmp_file}" 2>/dev/null; return 1; }
    ota_state_set_key "${tmp_file}" BACKUP_PARTIAL "${OTA_STATE_BACKUP_PARTIAL:-0}" || { rm -f "${tmp_file}" 2>/dev/null; return 1; }
    mv "${tmp_file}" "${state_file}" || { rm -f "${tmp_file}" 2>/dev/null; return 1; }
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

# ===== recovery retry helpers (operate on an explicit state file) =====

state_increment_retry() { # $1=state file
    local count

    count="$(ota_state_get_key "$1" RETRY_COUNT)"
    case "${count}" in ''|*[!0-9]*) count=0 ;; esac
    ota_state_set_key "$1" RETRY_COUNT "$((count + 1))"
}

state_get_retry_count() { # $1=state file
    local count

    count="$(ota_state_get_key "$1" RETRY_COUNT)"
    case "${count}" in ''|*[!0-9]*) echo 0 ;; *) echo "${count}" ;; esac
}

state_retry_exhausted() { # $1=state file
    [ "$(state_get_retry_count "$1")" -ge "${OTA_MAX_RETRY}" ]
}

state_reset_retry() { # $1=state file
    ota_state_set_key "$1" RETRY_COUNT 0
}

state_mark_failed() { # $1=state file $2=error message
    ota_state_set_key "$1" STATUS failed
    ota_state_set_key "$1" ERROR_MSG "$2"
    ota_state_set_key "$1" COMPLETE_TIME "$(date -Iseconds)"
}
