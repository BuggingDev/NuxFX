#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Regression check for patch 20: the non-2 KHR push descriptor entrypoints and
# a push-descriptor update template with the compute bind point. The compute
# shader writes 0xdeadbeef through the descriptor; a dropped descriptor leaves
# the buffer zero.
#
# Requires: cc, Vulkan headers and loader (libvulkan-dev, vulkan-tools for
# vulkaninfo is not needed), glslangValidator (glslang-tools), and dzn under WSL.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../scripts/common.sh"
aegnux_env

if ! command -v cc > /dev/null 2>&1; then
    echo "FAIL: cc not found ($(aegnux_pkg_hint gcc))"
    exit 1
fi
if ! command -v glslangValidator > /dev/null 2>&1; then
    echo "FAIL: glslangValidator not found ($(aegnux_pkg_hint glslangValidator))"
    exit 1
fi

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

cc -O2 -Wall -Wextra -o "$WORK/push_descriptor_test" "$HERE/push_descriptor_test.c" \
    $(pkg-config --cflags --libs vulkan 2>/dev/null || echo -lvulkan) || exit 1
glslangValidator -V -o "$WORK/shader.spv" "$HERE/push_descriptor.comp" > /dev/null || exit 1

RC=0
for mode in plain template; do
    echo "== $mode"
    timeout 30 "$WORK/push_descriptor_test" "$WORK/shader.spv" "$mode"
    rc=$?
    if [ "$rc" -eq 77 ]; then
        echo "SKIP: the selected Vulkan device does not support VK_KHR_push_descriptor"
        exit 0
    fi
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: push descriptor test ($mode) returned $rc"
        RC=1
    fi
done

if [ "$RC" -eq 0 ]; then
    echo "PASS: push descriptors reach the compute pipeline"
else
    echo "FAIL: push descriptors are dropped (patch 20 regression)"
fi
exit "$RC"
