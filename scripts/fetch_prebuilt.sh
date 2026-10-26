#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Install the prebuilt, patched Mesa 25.2.8 package of this project instead of building it:
#
#   scripts/fetch_prebuilt.sh dzn     the Vulkan driver (libvulkan_dzn.so) into DZN_PREFIX
#   scripts/fetch_prebuilt.sh gl      Mesa's EGL and Direct3D 12 OpenGL driver into AEGNUX_GL_PREFIX
#
# prebuilt/manifest.txt names the packages (release assets of this project) with their SHA-256 and the hash of the
# patch series they were built from. A package is used only when that hash is the one of patches/ in this checkout,
# so a changed patch never meets an old binary. Exit status 3 means that no package can be used (none fits, no
# network, wrong SHA-256, its libraries do not resolve here): nothing was changed, and the caller builds from source
# (build_dzn.sh, build_gl.sh).
#
#   AEGNUX_PREBUILT_BASE_URL   download from this place (a URL, or a local folder) instead of the one in the manifest
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"

COMPONENT=${1:-}
MESA_VERSION=25.2.8
MANIFEST="$AEGNUX_REPO/prebuilt/manifest.txt"
case "$COMPONENT" in
    dzn) PREFIX=$DZN_PREFIX; CHECK_LIBS="lib/libvulkan_dzn.so"; KEY=DZN_PREFIX ;;
    gl) PREFIX=$AEGNUX_GL_PREFIX; CHECK_LIBS="lib/libEGL.so.1 lib/libgallium-$MESA_VERSION.so"; KEY=AEGNUX_GL_PREFIX ;;
    *) echo "usage: $0 dzn|gl" >&2; exit 2 ;;
esac
unusable() { echo "prebuilt $COMPONENT: $*" >&2; exit 3; }

[ "$(uname -m)" = x86_64 ] || unusable "packages exist for x86_64 only"
[ -f "$MANIFEST" ] || unusable "this checkout has no prebuilt/manifest.txt"
SERIES=$(aegnux_series_hash)
ASSET=""; SHA=""; SIZE=0
read -r ASSET SHA SIZE < <(awk -v c="$COMPONENT" -v m="$MESA_VERSION" -v s="$SERIES" \
    '$1 == c && $2 == m && $3 == s && $4 == "x86_64" { print $5, $6, $7; exit }' "$MANIFEST") || true
[ -n "$ASSET" ] || unusable "no package for this patch series (${SERIES:0:12})"
BASE=${AEGNUX_PREBUILT_BASE_URL:-$(awk '$1 == "base" { print $2; exit }' "$MANIFEST")}
[ -n "$BASE" ] || unusable "the manifest has no base URL"

DL="$AEGNUX_HOME/downloads"
mkdir -p "$DL" || unusable "cannot create $DL"
FILE="$DL/$ASSET"
sha_ok() { [ -f "$FILE" ] && [ "$(sha256sum "$FILE" | cut -d' ' -f1)" = "$SHA" ]; }
if ! sha_ok; then
    echo "downloading $ASSET ($(( (SIZE + 1048575) / 1048576 )) MB)"
    case "$BASE" in
        /*|file://*)
            cp -- "${BASE#file://}/$ASSET" "$FILE" 2> /dev/null || unusable "cannot read ${BASE#file://}/$ASSET" ;;
        *)
            if [ -t 2 ]; then PROGRESS=-#; else PROGRESS=-sS; fi
            curl -fL --retry 3 --connect-timeout 20 -C - $PROGRESS -o "$FILE" "$BASE/$ASSET" || unusable "download failed: $BASE/$ASSET" ;;
    esac
    sha_ok || { rm -f "$FILE"; unusable "SHA-256 mismatch for $ASSET (removed the download)"; }
fi

# What the archive holds is checked before anything is unpacked: plain files, folders and links inside the folder.
LIST=$(tar --zstd -tvf "$FILE" 2> /dev/null) || unusable "$ASSET is not a readable archive"
if printf '%s\n' "$LIST" | cut -c1 | grep -qv '[-dl]'; then unusable "$ASSET holds special files"; fi
if tar --zstd -tf "$FILE" | grep -qE '^/|(^|/)\.\.(/|$)'; then unusable "$ASSET holds unsafe file names"; fi
if printf '%s\n' "$LIST" | grep ' -> ' | grep -qE ' -> (/|.*\.\.)'; then unusable "$ASSET holds unsafe links"; fi

PARENT=$(dirname "$PREFIX")
mkdir -p "$PARENT" 2> /dev/null || unusable "cannot create $PARENT"
STAGE=$(mktemp -d "$PARENT/.nuxfx-unpack.XXXXXX") || unusable "cannot write in $PARENT"
trap 'rm -rf "$STAGE"' EXIT
tar --zstd -xf "$FILE" -C "$STAGE" || unusable "cannot unpack $ASSET"
chmod 755 "$STAGE"

# Do the libraries load here (glibc, libstdc++ and every library they link)? ldd -r also resolves the symbols.
for l in $CHECK_LIBS; do
    [ -f "$STAGE/$l" ] || unusable "$ASSET has no $l"
    BAD=$(LD_LIBRARY_PATH="$STAGE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd -r "$STAGE/$l" 2>&1 | grep -E 'not found|undefined symbol' | head -n 4 | tr -s ' \t' ' ' | tr '\n' ';') || true
    [ -z "$BAD" ] || unusable "$l does not load on this system: $BAD"
done

OLD=""
if [ -e "$PREFIX" ]; then
    OLD=$(mktemp -u "$PARENT/.nuxfx-old.XXXXXX")
    mv -- "$PREFIX" "$OLD" || unusable "cannot replace $PREFIX"
fi
if ! mv -- "$STAGE" "$PREFIX"; then
    [ -n "$OLD" ] && mv -- "$OLD" "$PREFIX"
    unusable "cannot install into $PREFIX"
fi
[ -n "$OLD" ] && rm -rf -- "$OLD"
printf 'component=%s\nmesa=%s\nseries=%s\nasset=%s\nsha256=%s\n' "$COMPONENT" "$MESA_VERSION" "$SERIES" "$ASSET" "$SHA" > "$PREFIX/.nuxfx-prebuilt"

if [ "$COMPONENT" = dzn ]; then
    aegnux_write_dzn_icd
    # the optional apiVersion layer needs a compiler; it is off by default
    if command -v gcc > /dev/null 2>&1; then "$HERE/build_layer.sh" || true; fi
fi
mkdir -p "$(dirname "$AEGNUX_CONFIG")"
touch "$AEGNUX_CONFIG"
sed -i "/^$KEY=/d" "$AEGNUX_CONFIG"
printf '%s=%s\n' "$KEY" "$PREFIX" >> "$AEGNUX_CONFIG"
echo "prebuilt $COMPONENT installed in $PREFIX (settings saved to $AEGNUX_CONFIG)"
