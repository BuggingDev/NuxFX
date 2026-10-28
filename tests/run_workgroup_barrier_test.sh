#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Regression check for patch 28: a workgroup barrier that makes memory available and visible (the Vulkan memory model,
# as vkd3d-proton emits GroupMemoryBarrierWithGroupSync for DirectML) must not turn the group shared accesses around
# it into atomics. dzn did (one atomic exchange or add per access: 128 of them in a DirectML kernel of Roto Brush), and
# the Direct3D 12 driver of an NVIDIA GPU crashes while it compiles that. The test runs a compute shader with such a
# barrier (the result must be right) and counts the atomics in the NIR that dzn prints (DZN_DEBUG=nir); it fails when
# the shader needs any.
#
# Requires: cc, Vulkan headers and loader (libvulkan-dev), glslangValidator (glslang-tools), and a Vulkan driver with
# the Vulkan memory model (the test skips otherwise).
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

cc -O2 -Wall -Wextra -o "$WORK/workgroup_barrier_test" "$HERE/workgroup_barrier_test.c" \
    $(pkg-config --cflags --libs vulkan 2>/dev/null || echo -lvulkan) || exit 1
glslangValidator -V --target-env vulkan1.3 -o "$WORK/shader.spv" "$HERE/workgroup_barrier.comp" > "$WORK/glslang.txt" 2>&1 || { cat "$WORK/glslang.txt"; exit 1; }

DZN_DEBUG=nir timeout 60 "$WORK/workgroup_barrier_test" "$WORK/shader.spv" > "$WORK/out.txt" 2> "$WORK/nir.txt"
rc=$?
cat "$WORK/out.txt"
if [ "$rc" -eq 77 ]; then
    echo "SKIP: no Vulkan device with the Vulkan memory model"
    exit 0
fi
ATOMICS=$(grep -c 'deref_atomic' "$WORK/nir.txt")
echo "atomics in the NIR of the shader: $ATOMICS"
if [ "$rc" -ne 0 ]; then
    echo "FAIL: the shader did not give the right values behind a workgroup barrier"
    exit 1
fi
if [ "$ATOMICS" -gt 0 ]; then
    echo "FAIL: group shared accesses behind a workgroup barrier became atomics (patch 28 regression)"
    exit 1
fi
echo "PASS: group shared memory behind a workgroup barrier that makes memory available and visible stays plain loads and stores"
