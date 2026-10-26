#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Build the optional apiVersion Vulkan layer into AEGNUX_LAYER_DIR (AEGNUX_APIVER_LAYER=1 switches it on; patch 04
# made it unnecessary in the tested setup). It needs gcc and the Vulkan headers; without them it only says so.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"

if echo '#include <vulkan/vulkan.h>' | cc -E -x c - > /dev/null 2>&1; then
    mkdir -p "$AEGNUX_LAYER_DIR"
    gcc -shared -fPIC -O2 -o "$AEGNUX_LAYER_DIR/libapiver_layer.so" "$HERE/apiver_layer/apiver_layer.c"
    sed "s|__AEGNUX_LAYER_LIB__|$AEGNUX_LAYER_DIR/libapiver_layer.so|" \
        "$HERE/apiver_layer/VkLayer_AEGNUX_apiversion.json.in" > "$AEGNUX_LAYER_DIR/VkLayer_AEGNUX_apiversion.json"
else
    echo "note: the Vulkan headers are not installed (vulkan-headers, libvulkan-dev); the optional apiVersion layer is not built" >&2
fi
