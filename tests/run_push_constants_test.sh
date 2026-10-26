#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Regression check for patch 27: 16 dispatches of one command buffer, each recorded after its own
# vkCmdPushConstants, write 16 different values. dzn used one upload slot for all push constant updates
# of a command buffer, so every dispatch read the values of the last one (and DirectML's Roto Brush
# propagation and Content-Aware Fill hung the GPU through descriptor indices that were meant for other
# dispatches).
#
# Requires: cc, Vulkan headers and loader (libvulkan-dev), glslangValidator (glslang-tools), and a Vulkan driver.
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
aegnux_have_vulkan_headers || { echo "FAIL: the Vulkan headers are not installed ($(aegnux_pkg_hint libvulkan-dev))"; exit 1; }

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

cc -O2 -Wall -Wextra -o "$WORK/push_constants_test" "$HERE/push_constants_test.c" \
    $(pkg-config --cflags --libs vulkan 2>/dev/null || echo -lvulkan) || exit 1
glslangValidator -V -o "$WORK/shader.spv" "$HERE/push_constants.comp" > /dev/null || exit 1

timeout 60 "$WORK/push_constants_test" "$WORK/shader.spv"
rc=$?
if [ "$rc" -eq 77 ]; then
    echo "SKIP: no Vulkan device"
    exit 0
fi
if [ "$rc" -eq 0 ]; then
    echo "PASS: every dispatch of a command buffer reads the push constants it was recorded with"
else
    echo "FAIL: dispatches read other push constants than the ones set before them (patch 27 regression)"
    exit 1
fi
