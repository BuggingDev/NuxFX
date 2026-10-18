#!/bin/bash
# Clears AE's previous-crash state so that the "Crash Repair Options" dialog does
# not block startup. Run before every launch (launch_ae.sh does this).
set -eu
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"

TEMP_ADOBE="$WINEPREFIX/drive_c/users/$USER/AppData/Local/Temp/Adobe"
for d in "$TEMP_ADOBE/GPUSniffer/24.0/SentryIO-db" "$TEMP_ADOBE/After Effects/24.0/SentryIO-db"; do
    rm -rf "$d"/*.run "$d"/*.run.lock "$d"/last_crash 2>/dev/null || true
done

# Session state: a session that never reached a clean exit keeps AppState 0x3e8.
REG="$WINEPREFIX/user.reg"
if [ -f "$REG" ]; then
    sed -i 's/"AppState"=dword:000003e8/"AppState"=dword:000003e9/g; s/"CrashOccurred"=dword:00000001/"CrashOccurred"=dword:00000000/g' "$REG"
fi

DB="$WINEPREFIX/drive_c/users/$USER/AppData/Roaming/Adobe/After Effects/24.6/Debug Database.txt"
if [ -f "$DB" ]; then
    sed -i 's/^AE\.DebugShowPreviousCrashWarning\ttrue\ttrue/AE.DebugShowPreviousCrashWarning\tfalse\ttrue/' "$DB"
fi
echo "crash state cleared"