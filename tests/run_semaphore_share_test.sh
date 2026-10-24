#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Regression check for patch 21 (dzn shares timeline semaphores between devices through a memfd).
# Two Vulkan devices exchange a timeline semaphore as an opaque fd: CPU signals, queue signals and
# queue waits must cross, an imported semaphore must be exportable again, and destroying the
# semaphores must not crash. It runs natively, without Wine.
#
# Requires: cc, the Vulkan headers and loader (libvulkan-dev) and dzn under WSL (or any Vulkan driver
# with external semaphore fd support: the test is generic and skips when the device has none).
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

cc -O2 -Wall -Wextra -Wno-missing-field-initializers -o "$WORK/semaphore_share_test" "$HERE/semaphore_share_test.c" \
    $(pkg-config --cflags --libs vulkan 2> /dev/null || echo -lvulkan) -lpthread || exit 1

timeout 60 "$WORK/semaphore_share_test" 2>&1 | grep -v -E "^WARNING: dzn|^dzn: app apiVersion"
rc=${PIPESTATUS[0]}
if [ "$rc" -eq 77 ]; then
    echo "SKIP: the selected Vulkan device cannot share timeline semaphores"
    exit 0
fi
if [ "$rc" -eq 0 ]; then
    echo "PASS: a timeline semaphore is shared between two devices"
else
    echo "FAIL: timeline semaphore sharing between devices (exit status $rc; patch 21 regression)"
fi
exit "$rc"
