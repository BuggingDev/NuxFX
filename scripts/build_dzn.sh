#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Build Mesa 25.2.8 Dozen (dzn) with the aegnux patch series and install it.
#
#   MESA_SRC      unpacked Mesa 25.2.8 tree (default $HOME/src/mesa-25.2.8)
#   MESA_TARBALL  optional: mesa-25.2.8.tar.xz, unpacked into MESA_SRC if it is missing
#   DZN_PREFIX    install prefix for libvulkan_dzn.so and its ICD manifest
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
. "$HERE/common.sh"

MESA_VERSION=25.2.8
MESA_TARBALL_SHA256=097842f3e49d996868b38688db87b006f7d4541e93ce86d2f341d8b3e7be7c93

MISSING=$(aegnux_build_missing)
if [ -n "$MISSING" ]; then
    echo "the dzn build is missing:" >&2
    printf '%s\n' "$MISSING" | sed 's/^/  /' >&2
    echo "  $(aegnux_pkg_hint gcc gcc-c++ git pkg-config ninja python3-mako)" >&2
    echo "  $(aegnux_mesa_dev_hint)" >&2
    exit 1
fi
if ! is_d3d12_host; then
    echo "note: dzn needs Direct3D 12 (/dev/dxg); hosts with a native GPU driver use their own Vulkan driver." >&2
fi

if [ ! -f "$MESA_SRC/meson.build" ]; then
    : "${MESA_TARBALL:?set MESA_SRC to an unpacked Mesa $MESA_VERSION tree, or MESA_TARBALL to the release tarball}"
    echo "$MESA_TARBALL_SHA256  $MESA_TARBALL" | sha256sum -c -
    mkdir -p "$MESA_SRC"
    tar -xJf "$MESA_TARBALL" -C "$MESA_SRC" --strip-components=1
fi
if [ "$(cat "$MESA_SRC/VERSION" 2> /dev/null)" != "$MESA_VERSION" ]; then
    echo "MESA_SRC is not an unpacked Mesa $MESA_VERSION tree (VERSION: $(cat "$MESA_SRC/VERSION" 2> /dev/null || echo missing))" >&2
    exit 1
fi
TOP=$(git -C "$MESA_SRC" rev-parse --show-toplevel 2> /dev/null || true)
if [ -n "$TOP" ] && [ "$TOP" != "$(cd "$MESA_SRC" && pwd -P)" ]; then
    echo "MESA_SRC is inside another git repository ($TOP): git apply would skip the patch paths outside it. Use an unpacked tarball directory." >&2
    exit 1
fi

# Applied patches are recorded in this file, one per line as "<sha256>  <name>". A newer
# checkout applies only the patches it adds, and a patch that changed after it was applied is
# an error. Lines with only a name come from an older version of this script; they are
# trusted without a hash. If the file is missing or empty, the series is applied in order,
# and the newest patch that reverses cleanly shows how far an existing tree got.
APPLIED="$MESA_SRC/.aegnux-patches-applied"
PATCHES=("$REPO"/patches/*.patch)
# Patches whose text was reworded without changing the code (a commit message or a comment). A tree
# that applied one of the earlier versions is accepted, and its record is updated to the new hash.
# One line per earlier version: "<patch name> <sha256 of that version>".
REWORDED="0015-dzn-advertise-features-and-extensions-required-by-DX.patch 2b177b3e95a5a8de91143c047c1afbd664652445a84f4f210937bceb4d14a977
0017-dzn-implement-viewport-and-scissor-with-count.patch e8cf2c501f7fe877dbecfec8cc7b5f5d1927d7aa2766ddf3d075d313844cc330
0018-dzn-report-the-CUDA-device-UUID-as-the-device-UUID-u.patch 93da27b51fe046f5abd6459a03c27986b6ccf909da97e459c18dec85659a4bd1
0021-dzn-share-timeline-semaphores-through-a-memfd.patch 87be8eb25fa07f5445687420ce859a8b823b20ad1e901f2bbc2a6317b1b8b05e
0025-dzn-lower-gl_PatchVerticesIn-to-a-constant.patch 1c00144818ef7da0db9635e19a493a906ffa6bf1dc42ad5003c5403b519e63e8"
# A tree that was patched with a patch this series no longer has (the early series was renumbered) cannot
# take the new ones: git apply would fail on a change that is already there. Say so before it does.
if [ -s "$APPLIED" ]; then
    while read -r first rest; do
        name=${rest:-$first}
        if [ -n "$name" ] && [ ! -f "$REPO/patches/$name" ]; then
            echo "$MESA_SRC was patched with $name, which is not in this series any more (the series was renumbered)." >&2
            echo "Build in a fresh Mesa tree, for example: MESA_SRC=\$HOME/src/mesa-$MESA_VERSION-new MESA_BUILD=\$HOME/src/mesa-$MESA_VERSION-new/build MESA_TARBALL=<mesa-$MESA_VERSION.tar.xz> $0" >&2
            exit 1
        fi
    done < "$APPLIED"
fi
if [ ! -s "$APPLIED" ]; then
    : > "$APPLIED"
    for ((i = ${#PATCHES[@]} - 1; i >= 0; i--)); do
        if (cd "$MESA_SRC" && git apply --check --reverse "${PATCHES[$i]}" 2> /dev/null); then
            for ((j = 0; j <= i; j++)); do basename "${PATCHES[$j]}"; done > "$APPLIED"
            echo "tree already has patches up to $(basename "${PATCHES[$i]}")"
            break
        fi
    done
fi
for p in "${PATCHES[@]}"; do
    name=$(basename "$p")
    sum=$(sha256sum "$p" | cut -d' ' -f1)
    recorded=$(awk -v n="$name" '$2 == n { print $1; exit } $0 == n { print "-"; exit }' "$APPLIED")
    if [ -n "$recorded" ]; then
        if [ "$recorded" != "-" ] && [ "$recorded" != "$sum" ]; then
            if printf '%s\n' "$REWORDED" | grep -qx "$name $recorded"; then
                sed -i "s/^$recorded  $name\$/$sum  $name/" "$APPLIED"
            else
                echo "$name changed after it was applied to $MESA_SRC: restore it, or use a fresh Mesa tree." >&2
                exit 1
            fi
        fi
        continue
    fi
    echo "applying $name"
    (cd "$MESA_SRC" && git apply "$p")
    echo "$sum  $name" >> "$APPLIED"
done

MESON_OPTS=(
    -Dbuildtype=release
    -Dvulkan-drivers=microsoft-experimental
    -Dgallium-drivers=
    -Dplatforms=x11,wayland
    -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false
    -Dgles1=disabled -Dgles2=disabled -Dllvm=disabled
    -Dvalgrind=disabled -Dlibunwind=disabled
)
if [ -f "$MESA_BUILD/build.ninja" ]; then
    # Reconfigure so that a build directory left over from another source tree (or with
    # other options) fails here instead of silently building the wrong tree.
    meson setup --reconfigure "$MESA_BUILD" "$MESA_SRC" "${MESON_OPTS[@]}"
else
    meson setup "$MESA_BUILD" "$MESA_SRC" "${MESON_OPTS[@]}"
fi

ninja -C "$MESA_BUILD" src/microsoft/vulkan/libvulkan_dzn.so

mkdir -p "$DZN_PREFIX/lib" "$DZN_PREFIX/share/vulkan/icd.d"
install -m 755 "$MESA_BUILD/src/microsoft/vulkan/libvulkan_dzn.so" "$DZN_PREFIX/lib/"
cat > "$DZN_PREFIX/share/vulkan/icd.d/dzn_icd.x86_64.json" <<EOF
{
    "ICD": {
        "api_version": "1.3.318",
        "library_arch": "64",
        "library_path": "$DZN_PREFIX/lib/libvulkan_dzn.so"
    },
    "file_format_version": "1.0.1"
}
EOF

# Optional apiVersion layer (AEGNUX_APIVER_LAYER=1 enables it; patch 04 made it
# unnecessary in the tested setup)
if echo '#include <vulkan/vulkan.h>' | cc -E -x c - > /dev/null 2>&1; then
    mkdir -p "$AEGNUX_LAYER_DIR"
    gcc -shared -fPIC -O2 -o "$AEGNUX_LAYER_DIR/libapiver_layer.so" "$HERE/apiver_layer/apiver_layer.c"
    sed "s|__AEGNUX_LAYER_LIB__|$AEGNUX_LAYER_DIR/libapiver_layer.so|" \
        "$HERE/apiver_layer/VkLayer_AEGNUX_apiversion.json.in" > "$AEGNUX_LAYER_DIR/VkLayer_AEGNUX_apiversion.json"
else
    echo "note: the Vulkan headers are not installed (vulkan-headers, libvulkan-dev); the optional apiVersion layer is not built" >&2
fi

# Remember the locations so that the other scripts find this build without extra
# environment variables.
mkdir -p "$(dirname "$AEGNUX_CONFIG")"
touch "$AEGNUX_CONFIG"
for kv in "DZN_PREFIX=$DZN_PREFIX" "MESA_SRC=$MESA_SRC" "MESA_BUILD=$MESA_BUILD"; do
    sed -i "/^${kv%%=*}=/d" "$AEGNUX_CONFIG"
    printf '%s\n' "$kv" >> "$AEGNUX_CONFIG"
done

echo "dzn installed in $DZN_PREFIX (settings saved to $AEGNUX_CONFIG)"