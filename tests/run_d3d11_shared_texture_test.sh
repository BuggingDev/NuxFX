#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Regression check for patch 21 (dzn shares timeline semaphores between devices). Two D3D11
# devices share a texture through an NT handle and ID3D11Device1::OpenSharedResource1, once
# without and once with a keyed mutex; the second device must read what the first one wrote.
# Before patch 21 the keyed mutex case crashed: DXVK throws "Failed to import timeline semaphore"
# out of OpenSharedResource1 and the application dies (After Effects: "Crash in progress").
#
# Requires: x86_64-w64-mingw32-gcc, Xvfb and an installed dzn build. Only a private Xvfb display
# is used.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../scripts/common.sh"
aegnux_env

if ! command -v x86_64-w64-mingw32-gcc > /dev/null 2>&1; then
    echo "FAIL: x86_64-w64-mingw32-gcc not found ($(aegnux_pkg_hint mingw-w64))"
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

x86_64-w64-mingw32-gcc -O1 -Wall -o "$WORK/shared.exe" "$HERE/d3d11_shared_texture_test.c" \
    -ld3d11 -ldxgi -luuid || exit 1

cd "$WORK" || exit 1
RC=0
for mode in plain keyed; do
    echo "== $mode"
    timeout 90 wine shared.exe "$mode" > "out_$mode.txt" 2> "err_$mode.txt" < /dev/null
    rc=$?
    cat "out_$mode.txt"
    case "$rc" in
        0) ;;
        10) echo "FAIL: OpenSharedResource1 returned an error in the $mode case"
            grep -a -E "^err: " "err_$mode.txt" | sort -u | head -n 3
            RC=1 ;;
        11) echo "FAIL: the second device read the wrong colour in the $mode case"; RC=1 ;;
        *) echo "FAIL: the $mode case ended with status $rc (a crash?)"
           grep -a -E "terminate called|Unhandled|DxvkError" "err_$mode.txt" | sort -u | head -n 3
           RC=1 ;;
    esac
done
if [ "$RC" -eq 0 ]; then
    echo "PASS: a texture is shared between two D3D11 devices, with and without a keyed mutex"
else
    echo "FAIL: shared D3D11 textures (patch 21 regression)"
fi
exit "$RC"
