#!/bin/bash
# Stops After Effects and the wineserver of the aegnux prefix.
# The server must be stopped with WINEPREFIX set, or it keeps rewriting user.reg.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"
export WINEPREFIX

pkill -9 -f "AfterFX[.]exe" 2>/dev/null || true
pkill -9 -f "AdobeCrashRepo[r]t" 2>/dev/null || true
pkill -9 -f "crashpad_handle[r]" 2>/dev/null || true
sleep 2
"$WINE_BIN_DIR/wineserver" -k 2>/dev/null || true
for i in 1 2 3 4 5 6 7 8; do
    pgrep -x wineserver >/dev/null || break
    sleep 1
done
# Last resort: any wineserver of this user (there is normally only one).
pgrep -x wineserver >/dev/null && pkill -9 -x wineserver || true
echo "AE stopped"