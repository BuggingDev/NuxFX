#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Checks the VK_EXT_robustness2 behaviour that patch 15 advertises and that DXVK 3.0.1 and
# vkd3d-proton require (they use the driver's out-of-range behaviour to implement D3D11 and D3D12
# semantics): robustBufferAccess2 for storage and uniform buffer descriptors whose range is smaller
# than the buffer, robustImageAccess2 for storage images, and nullDescriptor for images and texel
# buffers (nullDescriptor for buffers is in run_descriptor_features_test.sh). Each case runs as its
# own process. Without Wine and After Effects.
#
# Requires: cc, the Vulkan headers and loader (libvulkan-dev), glslangValidator and dzn (or any
# Vulkan driver: the test is generic and skips what the device does not advertise).
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

cc -O1 -Wall -Wextra -Wno-missing-field-initializers -o "$WORK/robustness_test" \
    "$HERE/robustness_test.c" $(pkg-config --cflags --libs vulkan 2> /dev/null || echo -lvulkan) || exit 1
RC=0
for m in ssbo ubo image nullimage nulltexel; do
    glslangValidator -V -o "$WORK/$m.spv" "$HERE/robust_$m.comp" > "$WORK/glslang.log" 2>&1 || { cat "$WORK/glslang.log"; exit 1; }
    timeout 60 "$WORK/robustness_test" "$WORK/$m.spv" "$m" 2>&1 | grep -v -E "^WARNING: dzn|^dzn: app apiVersion"
    rc=${PIPESTATUS[0]}
    case "$rc" in
        0) ;;
        77) echo "SKIP: $m is not advertised by the selected device" ;;
        *) echo "FAIL: the $m case ended with status $rc"; RC=1 ;;
    esac
done
if [ "$RC" -eq 0 ]; then
    echo "PASS: out-of-range accesses and null descriptors behave as VK_EXT_robustness2 defines"
else
    echo "FAIL: robustness"
fi
exit "$RC"
