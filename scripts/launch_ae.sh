#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Launches After Effects 2024 under Wine with the dzn ICD and the apiVersion layer.
#
#   launch_ae.sh [SECONDS]   stop AE after SECONDS (default 0: no limit)
#
# Logs go to $AEGNUX_LOG_DIR/ae_<timestamp>/ (out.log, err.log, rc). The directory
# name is also written to $AEGNUX_LOG_DIR/LATEST.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"
SECS=${1:-0}

"$HERE/stop_ae.sh" > /dev/null 2>&1
sleep 2
"$HERE/clear_crash_state.sh" > /dev/null
"$HERE/ae_prefs.sh"
aegnux_env
if [ "$(aegnux_vulkan_mode)" = dzn ] && [ ! -f "$VK_ICD_FILENAMES" ]; then
    echo "dzn ICD not found: $VK_ICD_FILENAMES" >&2
    echo "Run scripts/build_dzn.sh or set DZN_PREFIX; scripts/doctor.sh shows what is missing." >&2
    exit 1
fi
if [ ! -f "$AE_DIR/AfterFX.exe" ]; then
    echo "AfterFX.exe not found in $AE_DIR (set AE_DIR)" >&2
    exit 1
fi

TS=$(date +%Y%m%d_%H%M%S)
LOGD="$AEGNUX_LOG_DIR/ae_$TS"
mkdir -p "$LOGD"
echo "$LOGD" > "$AEGNUX_LOG_DIR/LATEST"
cd "$AE_DIR"

if [ "$SECS" -gt 0 ]; then
    timeout -s TERM "$SECS" wine AfterFX.exe > "$LOGD/out.log" 2> "$LOGD/err.log" < /dev/null
else
    wine AfterFX.exe > "$LOGD/out.log" 2> "$LOGD/err.log" < /dev/null
fi
rc=$?
echo "rc=$rc" > "$LOGD/rc"
"$HERE/stop_ae.sh" > /dev/null 2>&1
echo "log directory: $LOGD (rc=$rc; 124 means the time limit ended)"