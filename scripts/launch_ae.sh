#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Launches After Effects 2024 under Wine with the dzn ICD. The apiVersion layer is optional
# (AEGNUX_APIVER_LAYER=1).
#
#   launch_ae.sh [SECONDS]   stop AE after SECONDS (default 0: no limit)
#
# If After Effects is already running in this prefix, nothing is started. AEGNUX_RESTART=1
# stops the running copy first; AE is then closed without saving.
# Logs go to $AEGNUX_LOG_DIR/ae_<timestamp>/ (out.log, err.log, rc). The directory
# name is also written to $AEGNUX_LOG_DIR/LATEST.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"
SECS=${1:-0}

RUNNING=$(aegnux_prefix_pids 'AfterFX[.]exe' | paste -sd ' ' -)
if [ -n "$RUNNING" ]; then
    if [ "${AEGNUX_RESTART:-0}" = 1 ]; then
        "$HERE/stop_ae.sh" > /dev/null 2>&1
        sleep 2
    else
        echo "After Effects is already running in this prefix (pid: $RUNNING). Close it, or run again with AEGNUX_RESTART=1 to stop it." >&2
        exit 1
    fi
fi
# The server writes user.reg when it stops, which would undo the edits made by
# clear_crash_state.sh. Stop it while no After Effects is running.
"$WINE_BIN_DIR/wineserver" -k > /dev/null 2>&1 || true
sleep 1
"$HERE/clear_crash_state.sh" > /dev/null
if [ "$(aegnux_wine_driver)" = wayland ]; then
    MISSING=$(aegnux_wayland_missing_symbols)
    if [ -n "$MISSING" ]; then
        echo "Wine's Wayland driver cannot load here: libwayland-client lacks $MISSING." >&2
        echo "Start After Effects in a session that has XWayland (DISPLAY is set; $(aegnux_pkg_hint xwayland)), or in an X11 session." >&2
        exit 1
    fi
fi
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
