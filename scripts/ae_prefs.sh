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

# HKCU\Software\Wine\Drivers Graphics = x11
#   Under WSLg and on Wayland desktops WAYLAND_DISPLAY is set, and this Wine build then
#   picks its Wayland driver, which was never tested with After Effects (on a private
#   Xvfb display the windows do not even appear there). Everything here was verified with
#   the X11 driver, so the prefix is told to use it.
if [ -f "$WINEPREFIX/user.reg" ] && ! grep -aq '^"Graphics"="x11"' "$WINEPREFIX/user.reg" \
   && [ -x "$WINE_BIN_DIR/wine" ]; then
    (
        aegnux_env
        wine reg add 'HKCU\Software\Wine\Drivers' /v Graphics /d x11 /f > /dev/null 2>&1
        timeout 30 "$WINE_BIN_DIR/wineserver" -w > /dev/null 2>&1
    )
    echo "Wine graphics driver set to x11"
fi

# set_db_pref FILE KEY VALUE DEFAULT: sets the value column and keeps the line ending.
set_db_pref() {
    local file=$1 key=$2 value=$3 default=$4 pat
    pat=$(printf '%s' "$key" | sed 's/\./\\./g')
    if [ -f "$file" ] && grep -q "^$pat$TAB" "$file"; then
        sed -i "s/^\($pat$TAB\)[^$TAB]*/\1$value/" "$file"
    else
        # AE replaces a Debug Database that has no AEDebugDatabaseVersion line with its own
        # defaults when it starts, so a first start would lose the flag. With the version line
        # AE keeps the file.
        if [ ! -f "$file" ]; then printf 'AEDebugDatabaseVersion\t2\t\r\r\n' > "$file"; fi
        printf '%s\t%s\t%s\r\r\n' "$key" "$value" "$default" >> "$file"
    fi
}

# set_pref FILE SECTION KEY VALUE: sets KEY = VALUE inside ["SECTION"] of an AE preferences
# file, adding the key (or the section) when it is missing. AE's files end lines with CRLF.
set_pref() {
    local file=$1 section=$2 key=$3 value=$4 tmp
    tmp=$(mktemp) || return 1
    tr -d '\r' < "$file" | awk -v sec="[\"$section\"]" -v key="$key" -v val="$value" '
        function out() { print "\t\"" key "\" = " val }
        $0 == sec { insec = 1; seen = 1; print; next }
        /^\[/ { if (insec && !done) { out(); done = 1 } insec = 0; print; next }
        insec && index($0, "\t\"" key "\" = ") == 1 { out(); done = 1; next }
        { print }
        END { if (insec && !done) out(); if (!seen) { print ""; print sec; out() } }
    ' | sed 's/$/\r/' > "$tmp" && cat "$tmp" > "$file"
    rm -f "$tmp"
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
    # AE writes its preferences file when it quits normally. On a first start there is none,
    # the Home screen opens as an empty panel over the whole workspace, and AE looks hung.
    # A minimal file with the setting is read like any other.
    if [ -n "$VERSION" ] && [ "${dir##*/}" = "$VERSION" ] \
       && [ ! -f "$dir/Adobe After Effects $VERSION Prefs.txt" ]; then
        printf '# Text File Version 1.1\r\n# After Effects Preferences\r\n' > "$dir/Adobe After Effects $VERSION Prefs.txt"
    fi
    for prefs in "$dir"/Adobe\ After\ Effects\ *\ Prefs.txt; do
        [ -f "$prefs" ] || continue
        if [ "${AEGNUX_HIDE_HOME_SCREEN:-1}" = 1 ]; then
            set_pref "$prefs" "General Section" "Show Welcome Screen" 00
        fi
        # The first-start tips pop up over the workspace; the tests switch them off.
        if [ "${AEGNUX_COACHMARKS:-1}" = 0 ]; then
            set_pref "$prefs" "Coachmarks Settings" "Enabled" 00
            set_pref "$prefs" "Coachmarks Seen By User" "Simple.Coachmarks.Enabled" 00
        fi
    done
    echo "AE preferences applied for ${dir##*/}"
done