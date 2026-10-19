#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Clears AE's previous-crash state so that the "Crash Repair Options" dialog does not block
# startup. launch_ae.sh runs it before every start. The Sentry records are moved to
# $AEGNUX_HOME/crash-archive/<timestamp>/ instead of being deleted, and the registry edits
# only touch the Software\Adobe\After Effects keys. Nothing is edited while the wineserver
# of this prefix is running, because the server rewrites user.reg.
set -eu
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"

TEMP_ADOBE="$WINEPREFIX/drive_c/users/$(aegnux_win_user)/AppData/Local/Temp/Adobe"
ARCHIVE="$AEGNUX_HOME/crash-archive/$(date +%Y%m%d_%H%M%S)"
MOVED=0
for d in "$TEMP_ADOBE"/*/*/SentryIO-db; do
    [ -d "$d" ] || continue
    rel=${d#"$TEMP_ADOBE"/}
    dest="$ARCHIVE/$(dirname "$rel" | tr '/' '_')"
    for f in "$d"/*.run "$d"/*.run.lock "$d"/last_crash; do
        [ -e "$f" ] || continue
        mkdir -p "$dest"
        mv "$f" "$dest/"
        MOVED=$((MOVED + 1))
    done
done

REG="$WINEPREFIX/user.reg"
if [ -f "$REG" ]; then
    if [ -n "$(aegnux_prefix_pids '[w]ineserver')" ]; then
        echo "wineserver of this prefix is running: registry not changed" >&2
    else
        TMP="$REG.aegnux-tmp"
        awk '
            /^\[/ { insec = ($0 ~ /^\[Software\\\\Adobe\\\\After Effects/) }
            insec && /^"AppState"=dword:000003e8/ { sub(/000003e8/, "000003e9") }
            insec && /^"CrashOccurred"=dword:00000001/ { sub(/00000001/, "00000000") }
            { print }
        ' "$REG" > "$TMP"
        mv "$TMP" "$REG"
    fi
fi

TAB=$(printf '\t')
aegnux_ae_pref_dirs | while IFS= read -r dir; do
    db="$dir/Debug Database.txt"
    [ -f "$db" ] || continue
    sed -i "s/^\(AE\.DebugShowPreviousCrashWarning$TAB\)true/\1false/" "$db"
done
echo "crash state cleared (moved $MOVED file(s))"
