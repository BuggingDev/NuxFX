#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# The prebuilt Mesa packages (prebuilt/manifest.txt, release assets of this project): the manifest belongs to the patches of
# this checkout; both packages download with the SHA-256 the manifest names, unpack into a private folder (your installation
# is not touched) and load on this system; scripts/fetch_prebuilt.sh refuses a damaged download, a package of another patch
# series and an archive that tries to leave its folder. No Wine and no After Effects. Needs curl, tar, zstd and ldd, and
# network access for the download (SKIP without them). AEGNUX_PREBUILT_BASE_URL takes the packages from another place.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
. "$REPO/scripts/common.sh"
fail() { echo "FAIL: $*"; exit 1; }

for t in curl tar zstd ldd sha256sum; do
    command -v "$t" > /dev/null || { echo "SKIP: $t is not installed ($(aegnux_pkg_hint curl tar zstd))"; exit 0; }
done
[ "$(uname -m)" = x86_64 ] || { echo "SKIP: the packages are for x86_64"; exit 0; }
MANIFEST="$REPO/prebuilt/manifest.txt"
[ -f "$MANIFEST" ] || fail "no prebuilt/manifest.txt"
SERIES=$(aegnux_series_hash)
for c in dzn gl; do
    line=$(awk -v c="$c" '$1 == c { print; exit }' "$MANIFEST")
    [ -n "$line" ] || fail "the manifest has no $c package"
    [ "$(echo "$line" | awk '{print $3}')" = "$SERIES" ] || fail "the $c package is of another patch series than patches/ here; build and run scripts/package_prebuilt.sh"
    echo "$line" | awk '{ exit !($6 ~ /^[0-9a-f]{64}$/ && $7 ~ /^[0-9]+$/) }' || fail "the $c line of the manifest is malformed"
done
echo "manifest: both packages are for patch series ${SERIES:0:12}"

X=$(mktemp -d) || exit 1
trap 'rm -rf "$X"' EXIT
export AEGNUX_HOME="$X/home" AEGNUX_CONFIG="$X/aegnux.conf" DZN_PREFIX="$X/dzn" AEGNUX_GL_PREFIX="$X/gl"
FETCH="$REPO/scripts/fetch_prebuilt.sh"
for c in dzn gl; do
    out=$("$FETCH" "$c" 2>&1); rc=$?
    if [ "$rc" != 0 ]; then
        case "$out" in
            *"download failed"*|*"cannot read"*) echo "SKIP: the $c package cannot be downloaded here ($(echo "$out" | tail -n 1))"; exit 0 ;;
        esac
        fail "fetch_prebuilt.sh $c (status $rc): $(echo "$out" | tail -n 1)"
    fi
done
[ -f "$X/dzn/lib/libvulkan_dzn.so" ] && [ -f "$X/gl/lib/libEGL.so.1" ] && [ -f "$X/gl/lib/libgallium-25.2.8.so" ] || fail "the packages did not unpack as expected"
grep -q "\"library_path\": \"$X/dzn/lib/libvulkan_dzn.so\"" "$X/dzn/share/vulkan/icd.d/dzn_icd.x86_64.json" || fail "the ICD manifest does not point at the unpacked library"
grep -q "^series=$SERIES\$" "$X/dzn/.nuxfx-prebuilt" || fail "the package record has the wrong series"
grep -q 'dzn-timeline-semaphore' "$X/dzn/lib/libvulkan_dzn.so" || fail "dzn lacks patch 21 (shared timeline semaphores)"
echo "both packages installed in a private folder and load here (glibc $(ldd --version | sed -n '1s/.* //p'))"

# a damaged download is refused and removed, and the install that was there stays
ASSET=$(awk '$1 == "dzn" { print $5; exit }' "$MANIFEST")
mkdir -p "$X/bad"
cp "$X/home/downloads/$ASSET" "$X/bad/$ASSET" && printf 'x' >> "$X/bad/$ASSET"
rm -f "$X/home/downloads/$ASSET"
AEGNUX_PREBUILT_BASE_URL="$X/bad" "$FETCH" dzn > /dev/null 2>&1; rc=$?
[ "$rc" = 3 ] || fail "a damaged download gave status $rc instead of 3"
[ -f "$X/dzn/lib/libvulkan_dzn.so" ] && [ ! -f "$X/home/downloads/$ASSET" ] || fail "a damaged download changed the install or stayed in the download folder"
echo "damaged download: refused (status 3), the install is unchanged"

# a checkout with another patch series finds no package
mkdir -p "$X/other" && cp -r "$REPO/scripts" "$REPO/patches" "$REPO/prebuilt" "$X/other/"
printf '# changed\n' >> "$(ls "$X"/other/patches/*.patch | head -n 1)"
"$X/other/scripts/fetch_prebuilt.sh" dzn > /dev/null 2>&1; rc=$?
[ "$rc" = 3 ] || fail "another patch series gave status $rc instead of 3"
echo "another patch series: no package (status 3)"

# an archive with a path that leaves its folder is refused before anything is unpacked
mkdir -p "$X/evil/lib" "$X/evildist" "$X/third/prebuilt"
cp -r "$REPO/scripts" "$REPO/patches" "$X/third/"
echo x > "$X/evil/lib/libvulkan_dzn.so"
(cd "$X/evil" && tar --transform='s,^lib,../lib,' -cf - lib 2> /dev/null | zstd -q -o "$X/evildist/evil.tar.zst")
printf 'base file:///nowhere\ndzn 25.2.8 %s x86_64 evil.tar.zst %s %s\n' "$SERIES" "$(sha256sum "$X/evildist/evil.tar.zst" | cut -d' ' -f1)" "$(stat -c %s "$X/evildist/evil.tar.zst")" > "$X/third/prebuilt/manifest.txt"
AEGNUX_PREBUILT_BASE_URL="$X/evildist" DZN_PREFIX="$X/dzn3" "$X/third/scripts/fetch_prebuilt.sh" dzn > /dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ ! -e "$X/dzn3" ] && [ ! -e "$X/lib" ] || fail "an archive with a path outside its folder was not refused (status $rc)"
echo "unsafe archive: refused (status 3), nothing unpacked"
echo "PASS: the prebuilt Mesa packages match the patches, install, load, and the checks refuse bad input"
