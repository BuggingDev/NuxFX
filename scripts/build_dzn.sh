#!/bin/bash
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

MISSING=""
for t in meson ninja pkg-config git python3; do command -v "$t" > /dev/null || MISSING="$MISSING $t"; done
command -v cc > /dev/null || MISSING="$MISSING gcc"
python3 -c 'import mako' 2> /dev/null || MISSING="$MISSING python3-mako"
if [ -n "$MISSING" ]; then
    echo "missing build tools:$MISSING" >&2
    echo "  $(aegnux_pkg_hint $MISSING)" >&2
    exit 1
fi
if ! is_wsl; then
    echo "note: dzn needs Direct3D 12 and only works under WSL; native Linux hosts use their own Vulkan driver." >&2
fi

if [ ! -f "$MESA_SRC/meson.build" ]; then
    : "${MESA_TARBALL:?set MESA_SRC to an unpacked Mesa $MESA_VERSION tree, or MESA_TARBALL to the release tarball}"
    echo "$MESA_TARBALL_SHA256  $MESA_TARBALL" | sha256sum -c -
    mkdir -p "$MESA_SRC"
    tar -xJf "$MESA_TARBALL" -C "$MESA_SRC" --strip-components=1
fi

if [ ! -f "$MESA_SRC/.aegnux-patches-applied" ]; then
    for p in "$REPO"/patches/*.patch; do
        echo "applying $(basename "$p")"
        (cd "$MESA_SRC" && git apply "$p")
    done
    touch "$MESA_SRC/.aegnux-patches-applied"
fi

if [ ! -f "$MESA_BUILD/build.ninja" ]; then
    meson setup "$MESA_BUILD" "$MESA_SRC" \
        -Dbuildtype=release \
        -Dvulkan-drivers=microsoft-experimental \
        -Dgallium-drivers= \
        -Dplatforms=x11,wayland \
        -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false \
        -Dgles1=disabled -Dgles2=disabled -Dllvm=disabled \
        -Dvalgrind=disabled -Dlibunwind=disabled
fi

ninja -C "$MESA_BUILD" src/microsoft/vulkan/libvulkan_dzn.so

mkdir -p "$DZN_PREFIX/lib" "$DZN_PREFIX/share/vulkan/icd.d"
install -m 755 "$MESA_BUILD/src/microsoft/vulkan/libvulkan_dzn.so" "$DZN_PREFIX/lib/"
cat > "$DZN_PREFIX/share/vulkan/icd.d/dzn_icd.x86_64.json" <<EOF
{
    "ICD": {
        "api_version": "1.1.318",
        "library_arch": "64",
        "library_path": "$DZN_PREFIX/lib/libvulkan_dzn.so"
    },
    "file_format_version": "1.0.1"
}
EOF

# Optional apiVersion layer (AEGNUX_APIVER_LAYER=1 enables it; patch 04 made it
# unnecessary in the tested setup)
mkdir -p "$AEGNUX_LAYER_DIR"
gcc -shared -fPIC -O2 -o "$AEGNUX_LAYER_DIR/libapiver_layer.so" "$HERE/apiver_layer/apiver_layer.c"
sed "s|__AEGNUX_LAYER_LIB__|$AEGNUX_LAYER_DIR/libapiver_layer.so|" \
    "$HERE/apiver_layer/VkLayer_AEGNUX_apiversion.json.in" > "$AEGNUX_LAYER_DIR/VkLayer_AEGNUX_apiversion.json"

# Remember the locations so that the other scripts find this build without extra
# environment variables.
mkdir -p "$(dirname "$AEGNUX_CONFIG")"
touch "$AEGNUX_CONFIG"
for kv in "DZN_PREFIX=$DZN_PREFIX" "MESA_SRC=$MESA_SRC" "MESA_BUILD=$MESA_BUILD"; do
    sed -i "/^${kv%%=*}=/d" "$AEGNUX_CONFIG"
    printf '%s\n' "$kv" >> "$AEGNUX_CONFIG"
done

echo "dzn installed in $DZN_PREFIX (settings saved to $AEGNUX_CONFIG)"