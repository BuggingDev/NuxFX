#!/bin/bash
# Regression check for patch 17 (dzn VIEWPORT_WITH_COUNT / SCISSOR_WITH_COUNT).
# Builds a D3D11 swapchain test, runs it under Wine with the aegnux environment,
# captures only that window, and fails unless the centre pixel is red.
#
# Requires: x86_64-w64-mingw32-gcc, gcc with X11 headers, xdotool, python3, and an
# installed dzn build. Point DZN_PREFIX / AEGNUX_LAYER_DIR at the install if it is
# not in the default location (see scripts/common.sh).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../scripts/common.sh"
aegnux_env
WORK=$(mktemp -d) || exit 1
x86_64-w64-mingw32-gcc -O1 -o "$WORK/dxgi_present_test.exe" "$HERE/dxgi_present_test.c" \
    -ld3d11 -ldxgi -luser32 -luuid -mwindows || exit 1
gcc -O1 -o "$WORK/xcap" "$HERE/../scripts/tools/xcap.c" -lX11 || exit 1
cd "$WORK" || exit 1
timeout 40 wine dxgi_present_test.exe > out.txt 2> err.txt < /dev/null &
WINE_PID=$!
sleep 4
if ! grep -q "create hr=0x00000000" out.txt 2>/dev/null; then
    echo "FAIL: D3D11 device creation failed (see $WORK/out.txt). Check DZN_PREFIX and AEGNUX_LAYER_DIR."
    wait "$WINE_PID"
    exit 1
fi
WID=$(xdotool search --name "dxgi_present_test" 2>/dev/null | head -1)
if [ -z "$WID" ]; then echo "FAIL: test window not found"; wait "$WINE_PID"; exit 1; fi
"$WORK/xcap" "$WID" "$WORK/window.ppm" || { echo "FAIL: window capture"; wait "$WINE_PID"; exit 1; }
wait "$WINE_PID"
python3 - "$WORK/window.ppm" << 'PY'
import sys
data = open(sys.argv[1], 'rb').read()
fields, pos = [], 0
while len(fields) < 4:
    while data[pos:pos + 1].isspace():
        pos += 1
    start = pos
    while not data[pos:pos + 1].isspace():
        pos += 1
    fields.append(data[start:pos])
w, h = int(fields[1]), int(fields[2])
pos += 1
off = pos + ((h // 2) * w + w // 2) * 3
r, g, b = data[off], data[off + 1], data[off + 2]
print(f"centre pixel = ({r}, {g}, {b}), window {w}x{h}")
sys.exit(0 if (r > 200 and g < 60 and b < 60) else 1)
PY
rc=$?
if [ $rc -eq 0 ]; then echo "PASS: swapchain shows backbuffer colour"; else echo "FAIL: window is not red (dzn present regression)"; fi
exit $rc