#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Package the patched Mesa 25.2.8 builds as the release assets that scripts/fetch_prebuilt.sh installs, and write
# prebuilt/manifest.txt for them.
#
#   scripts/package_prebuilt.sh [--out DIR] [--tag TAG]
#
# It packages what build_dzn.sh and build_gl.sh installed: set DZN_PREFIX, AEGNUX_GL_PREFIX and MESA_SRC to the folders
# of a build from source of this checkout (a fresh Mesa tree, so that the build holds exactly this patch series;
# the script checks the record that build_dzn.sh keeps in the tree). Build on the oldest system the packages must run
# on: they need the glibc and libstdc++ of the build host (readelf -V shows the versions).
#
#   --out DIR   where the assets go (default dist/ in the checkout)
#   --tag TAG   release tag the manifest points at (default mesa-<Mesa version>-s<first 8 characters of the series hash>)
# SOURCE_DATE_EPOCH (default: the commit time of HEAD, or now) is the modification time stored in the archives.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"

MESA_VERSION=25.2.8
MESA_TARBALL_SHA256=097842f3e49d996868b38688db87b006f7d4541e93ce86d2f341d8b3e7be7c93
OUT="$AEGNUX_REPO/dist"; TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=${2:?}; shift ;;
        --tag) TAG=${2:?}; shift ;;
        -h|--help) sed -n '5,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { echo "error: $*" >&2; exit 1; }
for t in tar zstd sha256sum readelf; do command -v "$t" > /dev/null || die "$t is not installed"; done
[ -f "$DZN_PREFIX/lib/libvulkan_dzn.so" ] || die "no $DZN_PREFIX/lib/libvulkan_dzn.so (run build_dzn.sh, or set DZN_PREFIX)"
[ -f "$AEGNUX_GL_PREFIX/lib/libgallium-$MESA_VERSION.so" ] || die "no $AEGNUX_GL_PREFIX/lib/libgallium-$MESA_VERSION.so (run build_gl.sh, or set AEGNUX_GL_PREFIX)"
[ "$(cat "$MESA_SRC/VERSION" 2> /dev/null)" = "$MESA_VERSION" ] || die "MESA_SRC is not the Mesa $MESA_VERSION tree of the build"
for f in docs/license.rst src/util/00-mesa-defaults.conf; do [ -f "$MESA_SRC/$f" ] || die "$MESA_SRC/$f is missing"; done

# The build must hold exactly the patches of this checkout.
APPLIED="$MESA_SRC/.aegnux-patches-applied"
[ -s "$APPLIED" ] || die "$APPLIED is missing: the tree was not patched by build_dzn.sh"
SERIES=$(aegnux_series_hash)
for p in "$AEGNUX_REPO"/patches/*.patch; do
    grep -qx "$(sha256sum "$p" | cut -d' ' -f1)  $(basename "$p")" "$APPLIED" || die "$(basename "$p") is not in $APPLIED as it is in this checkout; build in a fresh Mesa tree"
done
[ "$(grep -c . "$APPLIED")" = "$(ls "$AEGNUX_REPO"/patches/*.patch | wc -l)" ] || die "$APPLIED lists other patches than this checkout has; build in a fresh Mesa tree"

TAG=${TAG:-mesa-$MESA_VERSION-s${SERIES:0:8}}
EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$AEGNUX_REPO" log -1 --format=%ct 2> /dev/null || date +%s)}
BUILD_OS=$(. /etc/os-release 2> /dev/null; echo "${PRETTY_NAME:-Linux}")
GLIBC=$(ldd --version 2> /dev/null | sed -n '1s/.* //p')
GCC=$(gcc --version 2> /dev/null | sed -n 1p)
NPATCH=$(ls "$AEGNUX_REPO"/patches/*.patch | wc -l)
ARCH=x86_64
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

write_notes() { # DIR COMPONENT DESCRIPTION
    local d=$1/share/doc/nuxfx-mesa-$2
    mkdir -p "$d"
    cp "$MESA_SRC/docs/license.rst" "$d/LICENSE-Mesa.rst"
    # every license text Mesa uses (the code is MIT, individual files may differ), and the one of DirectX-Headers, which
    # Meson fetches and links into both libraries
    cp -r "$MESA_SRC/licenses" "$d/licenses"
    for f in "$MESA_SRC"/subprojects/DirectX-Headers-*/LICENSE; do
        [ -f "$f" ] && cp "$f" "$d/LICENSE-DirectX-Headers" || true
    done
    {
        echo "NuxFX prebuilt package: $2 ($3)"
        echo
        echo "Mesa:          $MESA_VERSION (https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz, sha256 $MESA_TARBALL_SHA256), MIT license (LICENSE-Mesa.rst, licenses/)"
        echo "Also linked:   DirectX-Headers (Microsoft, MIT license: LICENSE-DirectX-Headers)"
        echo "Patch series:  $SERIES ($NPATCH patches, the files of patches/ in https://github.com/BuggingDev/NuxFX)"
        echo "Built:         $(date -u +%Y-%m-%d) on $BUILD_OS, glibc $GLIBC, $GCC"
        echo "Built with:    scripts/build_dzn.sh and scripts/build_gl.sh of that repository (the Meson options are in them)"
        echo "Used by:       scripts/fetch_prebuilt.sh (the installer); the checksums are in prebuilt/manifest.txt"
        echo
        echo "sha256 of the patches:"
        (cd "$AEGNUX_REPO/patches" && LC_ALL=C sha256sum -- *.patch | sed 's/^/  /')
    } > "$d/SOURCE.txt"
}

pack() { # DIR OUTFILE
    chmod -R u=rwX,go=rX "$1"
    (cd "$1" && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$EPOCH" --format=gnu -cf - .) | zstd -19 -T0 -q -f -o "$2"
}

# dzn: the library and Mesa's default driver settings (the ICD manifest is written where the package is unpacked)
D=$WORK/dzn
mkdir -p "$D/lib" "$D/share/drirc.d"
install -m 755 "$DZN_PREFIX/lib/libvulkan_dzn.so" "$D/lib/"
install -m 644 "$MESA_SRC/src/util/00-mesa-defaults.conf" "$D/share/drirc.d/"
write_notes "$D" dzn "Vulkan driver of the Direct3D 12 route, libvulkan_dzn.so"

# gl: the libraries (no headers, static libraries or pkg-config files) and the default driver settings
G=$WORK/gl
mkdir -p "$G/lib" "$G/share"
(cd "$AEGNUX_GL_PREFIX/lib" && cp -a libEGL.so* libGLESv2.so* "libgallium-$MESA_VERSION.so" "$G/lib/")
[ -d "$AEGNUX_GL_PREFIX/share/drirc.d" ] && cp -a "$AEGNUX_GL_PREFIX/share/drirc.d" "$G/share/"
write_notes "$G" gl "EGL and the Direct3D 12 OpenGL driver of the Direct3D 12 route"

DZN_ASSET="nuxfx-mesa-dzn-$MESA_VERSION-s${SERIES:0:12}-$ARCH.tar.zst"
GL_ASSET="nuxfx-mesa-gl-$MESA_VERSION-s${SERIES:0:12}-$ARCH.tar.zst"
pack "$D" "$OUT/$DZN_ASSET"
pack "$G" "$OUT/$GL_ASSET"
(cd "$OUT" && sha256sum "$DZN_ASSET" "$GL_ASSET" > SHA256SUMS)

MANIFEST="$AEGNUX_REPO/prebuilt/manifest.txt"
mkdir -p "$(dirname "$MANIFEST")"
{
    echo "# NuxFX prebuilt Mesa packages, written by scripts/package_prebuilt.sh."
    echo "# <component> <Mesa version> <patch series sha256> <architecture> <asset> <sha256 of the asset> <size in bytes>"
    echo "# scripts/fetch_prebuilt.sh uses a package only when its series hash is the one of patches/ in the checkout."
    echo "base https://github.com/BuggingDev/NuxFX/releases/download/$TAG"
    for kv in "dzn:$DZN_ASSET" "gl:$GL_ASSET"; do
        c=${kv%%:*}; a=${kv#*:}
        echo "$c $MESA_VERSION $SERIES $ARCH $a $(sha256sum "$OUT/$a" | cut -d' ' -f1) $(stat -c %s "$OUT/$a")"
    done
} > "$MANIFEST"

echo "assets in $OUT:"; ls -l "$OUT/$DZN_ASSET" "$OUT/$GL_ASSET" "$OUT/SHA256SUMS" | awk '{print "  " $5 "  " $9}'
echo "manifest: $MANIFEST (release tag $TAG)"
echo "built on: $BUILD_OS, glibc $GLIBC; needs at least GLIBC_$(objdump -T "$DZN_PREFIX/lib/libvulkan_dzn.so" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -n 1 | cut -d_ -f2)"
