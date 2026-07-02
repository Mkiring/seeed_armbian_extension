#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_CLI="${SCRIPT_DIR}/../../runtime/bin/armbian-ota"

if [ ! -x "${RUNTIME_CLI}" ]; then
    RUNTIME_CLI="/usr/sbin/armbian-ota"
fi

exec "${RUNTIME_CLI}" start --mode=recovery "$1"
