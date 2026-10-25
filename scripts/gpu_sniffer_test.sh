#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Runs the dzn entrypoint audit, then the GPUSniffer DirectX test shipped with AE.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"
mkdir -p "$AEGNUX_TEST_DIR"
aegnux_have_vulkan_headers || { echo "FAIL: the Vulkan headers are not installed ($(aegnux_pkg_hint libvulkan-dev))"; exit 1; }

cc -O1 -Wall -o "$AEGNUX_TEST_DIR/dzn_audit" "$HERE/dzn_audit.c" -lvulkan || exit 1
MESA_SRC="$MESA_SRC" python3 "$HERE/gen_cmds.py" "$AEGNUX_TEST_DIR/audit_cmds.txt" || exit 1
aegnux_env
echo "== entrypoint audit"
"$AEGNUX_TEST_DIR/dzn_audit" "$AEGNUX_TEST_DIR/audit_cmds.txt" 2>&1 | grep -v conformant | tail -n 8

echo "== GPUSniffer"
cd "$AE_DIR"
timeout 150 wine GPUSniffer.exe > "$AEGNUX_TEST_DIR/gpusniffer.txt" 2>&1
echo "sniffer exit code: $?"
grep -a "GPUSniffer result" "$AEGNUX_TEST_DIR/gpusniffer.txt" | head -n 1 | cut -c1-120
echo "full output: $AEGNUX_TEST_DIR/gpusniffer.txt"