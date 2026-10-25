#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Build Mesa 25.2.8's EGL library and its Direct3D 12 OpenGL driver (Direct3D 12 route) and install them
# in their own prefix. aegnux_env puts that prefix first in LD_LIBRARY_PATH, so Wine's
# OpenGL (After Effects' Composition panel) runs on the same Mesa version on every
# distribution, whatever Mesa the distribution ships.
#
#   MESA_SRC          unpacked Mesa 25.2.8 tree (the one build_dzn.sh uses)
#   MESA_TARBALL      optional: mesa-25.2.8.tar.xz, unpacked into MESA_SRC if it is missing
#   AEGNUX_GL_PREFIX  install prefix (default $AEGNUX_HOME/mesa-gl)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"

MESA_VERSION=25.2.8
MESA_TARBALL_SHA256=097842f3e49d996868b38688db87b006f7d4541e93ce86d2f341d8b3e7be7c93
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
MISSING=$(aegnux_build_missing)
if [ -n "$MISSING" ]; then
    echo "the OpenGL build is missing:" >&2
    printf '%s\n' "$MISSING" | sed 's/^/  /' >&2
    echo "  $(aegnux_pkg_hint gcc gcc-c++ git pkg-config ninja python3-mako)" >&2
    echo "  $(aegnux_mesa_dev_hint)" >&2
    exit 1
fi
if ! is_d3d12_host; then
    echo "note: the Direct3D 12 OpenGL driver needs Direct3D 12 (/dev/dxg); hosts with a native GPU driver use their own OpenGL driver." >&2
fi

GL_BUILD="$MESA_SRC/build-gl"
MESON_OPTS=(
    -Dbuildtype=release
    -Dprefix="$AEGNUX_GL_PREFIX"
    -Dlibdir=lib
    -Dvulkan-drivers=
    -Dgallium-drivers=d3d12
    -Dgallium-d3d12-video=disabled
    -Dplatforms=x11
    -Dglx=disabled -Degl=enabled -Dgbm=disabled -Dopengl=true
    -Dgles1=disabled -Dgles2=enabled -Dllvm=disabled
    -Dvalgrind=disabled -Dlibunwind=disabled -Dglvnd=disabled
    -Dgallium-va=disabled -Dgallium-vdpau=disabled -Dgallium-rusticl=false
    -Dintel-rt=disabled -Dtools=
)
if [ -f "$GL_BUILD/build.ninja" ]; then
    meson setup --reconfigure "$GL_BUILD" "$MESA_SRC" "${MESON_OPTS[@]}"
else
    meson setup "$GL_BUILD" "$MESA_SRC" "${MESON_OPTS[@]}"
fi
ninja -C "$GL_BUILD"
ninja -C "$GL_BUILD" install

[ -f "$AEGNUX_GL_PREFIX/lib/libEGL.so.1" ] || { echo "the install has no $AEGNUX_GL_PREFIX/lib/libEGL.so.1" >&2; exit 1; }
mkdir -p "$(dirname "$AEGNUX_CONFIG")"
touch "$AEGNUX_CONFIG"
sed -i '/^AEGNUX_GL_PREFIX=/d' "$AEGNUX_CONFIG"
printf 'AEGNUX_GL_PREFIX=%s\n' "$AEGNUX_GL_PREFIX" >> "$AEGNUX_CONFIG"
echo "OpenGL stack installed in $AEGNUX_GL_PREFIX (settings saved to $AEGNUX_CONFIG)"
