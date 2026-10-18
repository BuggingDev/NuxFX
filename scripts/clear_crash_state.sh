#!/bin/bash
# Clears AE's previous-crash state so that the "Crash Repair Options" dialog does
# not block startup. Run before every launch (launch_ae.sh does this). Covers every
# After Effects and GPUSniffer version found in the prefix.
set -eu
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"

TEMP_ADOBE="$WINEPREFIX/drive_c/users/$(aegnux_win_user)/AppData/Local/Temp/Adobe"
for d in "$TEMP_ADOBE"/*/*/SentryIO-db; do
    [ -d "$d" ] || continue
    rm -rf "$d"/*.run "$d"/*.run.lock "$d"/last_crash 2>/dev/null || true
done

# Session state: a session that never reached a clean exit keeps AppState 0x3e8.
REG="$WINEPREFIX/user.reg"
if [ -f "$REG" ]; then
    sed -i 's/"AppState"=dword:000003e8/"AppState"=dword:000003e9/g; s/"CrashOccurred"=dword:00000001/"CrashOccurred"=dword:00000000/g' "$REG"
fi

TAB=$(printf '\t')
aegnux_ae_pref_dirs | while IFS= read -r dir; do
    db="$dir/Debug Database.txt"
    [ -f "$db" ] || continue
    sed -i "s/^\(AE\.DebugShowPreviousCrashWarning$TAB\)true/\1false/" "$db"
done
echo "crash state cleared"