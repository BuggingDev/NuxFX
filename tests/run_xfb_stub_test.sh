#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Checks that dzn's transform feedback stubs (patches 09 and 23) say so: a program that binds
# transform feedback buffers twice must make dzn print one warning line, and must run to the end.
# On a Vulkan driver other than dzn the program only has to run (and skips without the extension).
# Without Wine and After Effects.
#
# Requires: cc, the Vulkan headers and loader (libvulkan-dev) and dzn.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../scripts/common.sh"
aegnux_env

if ! command -v cc > /dev/null 2>&1; then
    echo "FAIL: cc not found ($(aegnux_pkg_hint gcc))"
    exit 1
fi
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
cc -O1 -Wall -Wextra -o "$WORK/xfb_stub_test" "$HERE/xfb_stub_test.c" $(pkg-config --cflags --libs vulkan 2> /dev/null || echo -lvulkan) || exit 1

timeout 60 "$WORK/xfb_stub_test" > "$WORK/out.txt" 2> "$WORK/err.txt"
rc=$?
cat "$WORK/out.txt"
if [ "$rc" -eq 77 ]; then echo "SKIP: transform feedback is not available"; exit 0; fi
if [ "$rc" -ne 0 ]; then
    echo "FAIL: the program ended with status $rc"
    tail -n 5 "$WORK/err.txt"
    exit 1
fi
WARNINGS=$(grep -c 'VK_EXT_transform_feedback is not implemented' "$WORK/err.txt")
echo "warning lines: $WARNINGS"
if [ "$(aegnux_vulkan_mode)" = dzn ]; then
    if [ "$WARNINGS" -eq 1 ]; then
        echo "PASS: dzn warned once that transform feedback is not implemented"
        exit 0
    fi
    echo "FAIL: expected one warning line from dzn (is the dzn build older than patch 23?)"
    exit 1
fi
echo "PASS: the transform feedback entrypoints ran (not dzn: no warning expected)"
