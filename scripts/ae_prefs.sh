#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Applies the After Effects preferences this setup needs, in every AE preferences
# folder of the prefix and in the folder of the installed version (so the first
# start is covered too). Idempotent; launch_ae.sh runs it before each start.
#
# DS.DisableDirectXDisplay = true (Debug Database.txt)
#   When CUDA is available, AE shows frames in the Composition panel through its
#   DirectX display, which passes images between CUDA and Direct3D 12. Wine's CUDA
#   bridge cannot share resources with vkd3d-proton, so that display never presents
#   and the panel stays empty. With this setting AE uses its non-DirectX display.
#   AEGNUX_DIRECTX_DISPLAY=1 leaves the setting alone.
# "Show Welcome Screen" = 00 (Adobe After Effects <version> Prefs.txt)
#   The HTML Home screen renders as an empty panel that covers the workspace.
#   AEGNUX_HIDE_HOME_SCREEN=0 leaves the setting alone.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"

TAB=$(printf '\t')

# set_db_pref FILE KEY VALUE DEFAULT: sets the value column and keeps the line ending.
set_db_pref() {
    local file=$1 key=$2 value=$3 default=$4 pat
    pat=$(printf '%s' "$key" | sed 's/\./\\./g')
    if [ -f "$file" ] && grep -q "^$pat$TAB" "$file"; then
        sed -i "s/^\($pat$TAB\)[^$TAB]*/\1$value/" "$file"
    else
        printf '%s\t%s\t%s\r\r\n' "$key" "$value" "$default" >> "$file"
    fi
}

ROAMING=$(aegnux_ae_roaming)
VERSION=$(aegnux_ae_version)
DIRS=$(aegnux_ae_pref_dirs)
if [ -n "$VERSION" ] && ! printf '%s\n' "$DIRS" | grep -qxF "$ROAMING/$VERSION"; then
    mkdir -p "$ROAMING/$VERSION"
    DIRS=$(printf '%s\n%s\n' "$DIRS" "$ROAMING/$VERSION")
fi

printf '%s\n' "$DIRS" | while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ "${AEGNUX_DIRECTX_DISPLAY:-0}" != 1 ]; then
        set_db_pref "$dir/Debug Database.txt" DS.DisableDirectXDisplay true false
    fi
    if [ "${AEGNUX_HIDE_HOME_SCREEN:-1}" = 1 ]; then
        for prefs in "$dir"/Adobe\ After\ Effects\ *\ Prefs.txt; do
            if [ -f "$prefs" ]; then
                sed -i 's/"Show Welcome Screen" = 01/"Show Welcome Screen" = 00/' "$prefs"
            fi
        done
    fi
    echo "AE preferences applied for ${dir##*/}"
done