#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Stops After Effects and the wineserver of the aegnux prefix, and nothing else. A process
# is stopped only if its command line matches and its environment has this prefix's
# WINEPREFIX, so other Wine prefixes and other programs (Chromium and Electron crash
# handlers, for example) are left alone. The server is asked to stop first, so that it
# writes user.reg before it exits.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"
export WINEPREFIX

# Sends TERM to this prefix's processes that match $1, then KILL if any are still there
# after five seconds.
stop_matching() {
    local pids
    pids=$(aegnux_prefix_pids "$1")
    [ -n "$pids" ] || return 0
    kill -TERM $pids 2> /dev/null || true
    for _ in 1 2 3 4 5; do
        sleep 1
        pids=$(aegnux_prefix_pids "$1")
        [ -n "$pids" ] || return 0
    done
    kill -KILL $pids 2> /dev/null || true
}

stop_matching "AfterFX[.]exe"
stop_matching "AdobeCrashRepo[r]t"
stop_matching "crashpad_handle[r]"

"$WINE_BIN_DIR/wineserver" -k 2> /dev/null || true
for _ in 1 2 3 4 5 6 7 8; do
    [ -n "$(aegnux_prefix_pids '[w]ineserver')" ] || break
    sleep 1
done
stop_matching "[w]ineserver"
echo "AE stopped"
