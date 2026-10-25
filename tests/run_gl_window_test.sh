#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Regression check for OpenGL child windows under Wine. After Effects draws its
# Composition panel with OpenGL into a child window. Wine can show such a window only if
# its X11 driver can load libXcomposite; without that library the panel stays black
# although the frames render (the library is opened at run time, so nothing complains).
#
# Needs no After Effects: a small Windows program opens a window with an OpenGL child
# window that is cleared to cyan, and the test looks at a screenshot of a private Xvfb
# display for the cyan pixels.
#
# Requires: Xvfb, xwininfo, python3, gcc with X11 headers, and the mingw-w64 compiler.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S="$HERE/../scripts"
. "$S/common.sh"

for t in Xvfb xwininfo python3 gcc x86_64-w64-mingw32-gcc; do
    if ! command -v "$t" > /dev/null; then
        echo "FAIL: $t not installed ($(aegnux_pkg_hint xvfb x11-utils python3 gcc libx11-dev mingw-gcc))"
        exit 1
    fi
done
WORK=$(mktemp -d) || exit 1
x86_64-w64-mingw32-gcc -O1 -o "$WORK/gl_window_test.exe" "$HERE/gl_window_test.c" -lopengl32 -lgdi32 -luser32 || exit 1
gcc -O1 -o "$WORK/xcap" "$S/tools/xcap.c" -lX11 || exit 1

# Abstract X sockets of servers that run in another mount namespace but share this network
# namespace (containers, other distributions) count as taken too (/proc/net/unix lists them).
N=99
while [ -e "/tmp/.X$N-lock" ] || grep -q "@/tmp/.X11-unix/X$N\$" /proc/net/unix 2> /dev/null; do N=$((N - 1)); done
Xvfb ":$N" -screen 0 1920x1080x24 -nolisten tcp > /dev/null 2>&1 &
XVFB_PID=$!
export DISPLAY=":$N"
unset WAYLAND_DISPLAY
cleanup() {
    kill "$XVFB_PID" 2> /dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
for _ in $(seq 1 50); do xwininfo -root > /dev/null 2>&1 && break; sleep 0.2; done
xwininfo -root > /dev/null 2>&1 || { echo "FAIL: Xvfb did not start on $DISPLAY"; exit 1; }

aegnux_env
# The first Wine start in a new prefix creates the prefix, which takes up to a minute.
( cd "$WORK" && timeout 150 wine gl_window_test.exe 120 > "$WORK/out.log" 2> "$WORK/err.log" < /dev/null ) &
WINE_PID=$!

ROOT=$(xwininfo -root | awk '/Window id:/{print $4}')
CYAN=0
for _ in $(seq 1 45); do
    sleep 2
    "$WORK/xcap" "$ROOT" "$WORK/screen.ppm" > /dev/null 2>&1 || continue
    CYAN=$(python3 - "$WORK/screen.ppm" << 'PY'
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
pix = data[pos + 1:]
print(sum(1 for i in range(0, len(pix) - 2, 3) if pix[i] < 40 and pix[i + 1] > 215 and pix[i + 2] > 215))
PY
)
    CYAN=${CYAN:-0}
    [ "$CYAN" -gt 100000 ] && break
done
CYAN=${CYAN:-0}
# Stop only the test program: another program (After Effects) may be running in this prefix.
wine taskkill /f /im gl_window_test.exe > /dev/null 2>&1
wait "$WINE_PID" 2> /dev/null

RENDERER=$(sed -n 's/^GL_RENDERER //p' "$WORK/out.log" | head -n 1)
echo "OpenGL renderer: ${RENDERER:-none}; $(grep -m1 'reads back' "$WORK/out.log" || echo 'no read-back')"
echo "cyan pixels on the screen: $CYAN (a working child window shows about 220000)"
if [ "$CYAN" -gt 100000 ]; then
    echo "PASS: the OpenGL child window reaches the screen"
    exit 0
fi
if [ -z "$RENDERER" ]; then
    echo "FAIL: Wine could not create an OpenGL context (see scripts/doctor.sh; log: $WORK/err.log)"
else
    MISSING=$(aegnux_wine_libs_missing | tr '\n' ' ')
    echo "FAIL: OpenGL renders, but the child window stays black${MISSING:+; missing libraries: $MISSING($(aegnux_pkg_hint $MISSING))}"
fi
mkdir -p "$AEGNUX_TEST_DIR"
cp "$WORK/screen.ppm" "$AEGNUX_TEST_DIR/gl_window_test.ppm" 2> /dev/null && echo "screen: $AEGNUX_TEST_DIR/gl_window_test.ppm"
exit 1
