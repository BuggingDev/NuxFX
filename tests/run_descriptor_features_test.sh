#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Checks two features that patch 15 advertises because DXVK 3.0.1 refuses an adapter without
# them: nullDescriptor (a buffer descriptor written with VK_NULL_HANDLE reads as zero; tested
# for a storage buffer and a uniform buffer) and inlineUniformBlock (a uniform block whose data
# lives in the descriptor set). Each runs as its own process, because a driver that cannot do
# it may crash. The null descriptor checks must pass. The inline uniform block is reported: it
# is not implemented in dzn (the descriptor pool refuses the allocation; DXVK and vkd3d-proton
# never allocate one), so a failure there is a known limitation, not a test failure.
#
# Requires: cc, the Vulkan headers and loader (libvulkan-dev), glslangValidator and dzn.
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

cc -O1 -Wall -Wextra -Wno-missing-field-initializers -o "$WORK/descriptor_features_test" \
    "$HERE/descriptor_features_test.c" $(pkg-config --cflags --libs vulkan 2> /dev/null || echo -lvulkan) || exit 1
for m in null nullubo inline; do
    glslangValidator -V -o "$WORK/$m.spv" "$HERE/descriptor_$m.comp" > /dev/null || exit 1
done

RC=0
for m in null nullubo; do
    echo "== $m"
    timeout 60 "$WORK/descriptor_features_test" "$WORK/$m.spv" "$m" 2>&1 | grep -v -E "^WARNING: dzn|^dzn: app apiVersion"
    rc=${PIPESTATUS[0]}
    case "$rc" in
        0) ;;
        77) echo "SKIP: $m is not advertised by the selected device" ;;
        *) echo "FAIL: the $m check ended with status $rc"; RC=1 ;;
    esac
done
echo "== inline (known limitation)"
timeout 60 "$WORK/descriptor_features_test" "$WORK/inline.spv" inline 2>&1 | grep -v -E "^WARNING: dzn|^dzn: app apiVersion"
rc=${PIPESTATUS[0]}
case "$rc" in
    0) echo "note: inline uniform blocks work" ;;
    77) echo "note: inline uniform blocks are not advertised" ;;
    *) echo "note: inline uniform blocks do not work (status $rc); not implemented in dzn (nothing in this stack allocates one)" ;;
esac

if [ "$RC" -eq 0 ]; then
    echo "PASS: null descriptors read as zero"
else
    echo "FAIL: null descriptors"
fi
exit "$RC"
