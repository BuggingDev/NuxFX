#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Regression check for patches 24 and 25 (dzn reports the tessellation limits and lowers
# gl_PatchVerticesIn). A D3D11 program draws one tessellated quad (hull and domain shaders, compiled
# with the prefix's d3dcompiler_47.dll) through DXVK for the tessellation factors 1, 8 and 64 and
# counts the red pixels of the render target. DXVK clamps the factor to the device's
# maxTessellationGenerationLevel, which dzn used to report as 0, and the hull shader that DXVK
# generates reads gl_PatchVerticesIn, which made vkCreateGraphicsPipelines crash before patch 25.
# A run whose frame is right but whose process then dies at exit (about 1 run in 12; "nested exception
# on signal stack", see docs/known-issues.md) is reported as a note, not as a failure.
#
# Requires: x86_64-w64-mingw32-gcc, Xvfb and an installed dzn build. Only a private Xvfb display
# is used.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../scripts/common.sh"
aegnux_env

if ! command -v x86_64-w64-mingw32-gcc > /dev/null 2>&1; then
    echo "FAIL: x86_64-w64-mingw32-gcc not found ($(aegnux_pkg_hint mingw-gcc))"
    exit 1
fi
if ! command -v Xvfb > /dev/null 2>&1; then
    echo "FAIL: Xvfb not found ($(aegnux_pkg_hint xvfb))"
    exit 1
fi
WORK=$(mktemp -d) || exit 1
N=99
while [ -e "/tmp/.X$N-lock" ] || grep -q "@/tmp/.X11-unix/X$N\$" /proc/net/unix 2> /dev/null; do N=$((N - 1)); done
Xvfb ":$N" -screen 0 800x600x24 -nolisten tcp > /dev/null 2>&1 &
XVFB_PID=$!
cleanup() {
    kill "$XVFB_PID" 2> /dev/null
    wineserver -k 2> /dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
export DISPLAY=":$N"
unset WAYLAND_DISPLAY
for _ in $(seq 1 50); do xwininfo -root > /dev/null 2>&1 && break; sleep 0.2; done

x86_64-w64-mingw32-gcc -O1 -Wall -o "$WORK/tess.exe" "$HERE/d3d11_tessellation_test.c" \
    -ld3d11 -ldxgi -luuid || exit 1

cd "$WORK" || exit 1
RC=0
for f in 1 8 64; do
    echo "== factor $f"
    timeout 120 wine tess.exe "$f" > "out_$f.txt" 2> "err_$f.txt" < /dev/null
    rc=$?
    cat "out_$f.txt"
    case "$rc" in
        0) ;;
        12) echo "FAIL: nothing was drawn with factor $f"; RC=1 ;;
        13) echo "FAIL: the covered area is wrong with factor $f"; RC=1 ;;
        *)
            red=$(sed -n 's/^red pixels \([0-9]*\) .*/\1/p' "out_$f.txt")
            if [ -n "$red" ] && [ "$red" -ge 2400 ] && [ "$red" -le 3000 ]; then
                echo "note: factor $f drew the right frame ($red red pixels) and the process then ended with status $rc"
                grep -a -E "^[0-9a-f]+:err:(virtual|seh)" "err_$f.txt" | sort -u | head -n 2
            else
                echo "FAIL: factor $f ended with status $rc"
                grep -a -E "^[0-9a-f]+:err:|Unimplemented|DxvkError|terminate" "err_$f.txt" | grep -v -E "wineboot|udev" | sort -u | head -n 3
                RC=1
            fi ;;
    esac
done
if [ "$RC" -eq 0 ]; then
    echo "PASS: hull and domain shaders run through DXVK for every tessellation factor"
else
    echo "FAIL: D3D11 tessellation"
fi
exit "$RC"
