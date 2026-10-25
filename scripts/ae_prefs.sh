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
# MyriadPro-Regular.otf in the prefix's Fonts folder, from After Effects' own pdfl/Fonts
#   (below): the default font of new text layers. AEGNUX_DEFAULT_FONT=0 leaves the prefix alone.
# dvaaudiodevice.ForceNoDevices = true (Debug Database.txt), only when the audio plan is "nodevice" (an RDP
#   sink (the sound server of the Direct3D 12 route) and no pacat to play the silent stream, or AEGNUX_AUDIO_DEVICES=0; see
#   aegnux_audio_plan in common.sh): After Effects is told there is no audio device, so it opens no stream
#   that could hang, and plays no sound. Set back to false whenever the plan is another one.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"

TAB=$(printf '\t')

# HKCU\Software\Wine\Drivers Graphics = x11 | wayland
#   On a Wayland desktop WAYLAND_DISPLAY is set, and this Wine build then picks its Wayland
#   driver on its own. Everything here was verified with the X11 driver (XWayland on a
#   Wayland desktop), so the prefix is told to use it whenever an X display exists. Wine's own
#   Wayland driver is used when there is no X display, or with AEGNUX_WAYLAND=1
#   (aegnux_wine_driver in common.sh).
DRIVER=$(aegnux_wine_driver)
if [ -f "$WINEPREFIX/user.reg" ] && ! grep -aq "^\"Graphics\"=\"$DRIVER\"" "$WINEPREFIX/user.reg" \
   && [ -x "$WINE_BIN_DIR/wine" ]; then
    (
        aegnux_env
        wine reg add 'HKCU\Software\Wine\Drivers' /v Graphics /d "$DRIVER" /f > /dev/null 2>&1
        timeout 30 "$WINE_BIN_DIR/wineserver" -w > /dev/null 2>&1
    )
    echo "Wine graphics driver set to $DRIVER"
fi

# Myriad Pro in the prefix's Fonts folder
#   After Effects gives a new text layer the default font MyriadPro-Regular. When Wine does not have
#   it, After Effects takes a font from its list by rules of its own, and with many fonts installed
#   (the Noto families that most desktops have) that was NotoSansSignWriting, which has no Latin
#   letters: every new text layer, 2D or 3D, looked empty. After Effects ships Myriad Pro in
#   pdfl/Fonts; copying that file into the prefix makes it the default again. It is Adobe's own file
#   from your installation, copied inside your own prefix. AEGNUX_DEFAULT_FONT=0 leaves the prefix alone.
FONT_SRC="$AE_DIR/pdfl/Fonts/MyriadPro-Regular.otf"
FONT_DST="$WINEPREFIX/drive_c/windows/Fonts"
if [ "${AEGNUX_DEFAULT_FONT:-1}" != 0 ] && [ -f "$FONT_SRC" ] && [ -d "$WINEPREFIX/drive_c/windows" ] \
   && [ ! -f "$FONT_DST/MyriadPro-Regular.otf" ]; then
    mkdir -p "$FONT_DST" && cp "$FONT_SRC" "$FONT_DST/MyriadPro-Regular.otf" \
        && echo "Myriad Pro copied into the Wine fonts folder (After Effects' default text font)"
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

# set_pref FILE SECTION KEY VALUE: sets KEY = VALUE inside ["SECTION"] of an AE preferences file
# (aegnux_set_pref in common.sh).
set_pref() { aegnux_set_pref "$@"; }

ROAMING=$(aegnux_ae_roaming)
VERSION=$(aegnux_ae_version)
DIRS=$(aegnux_ae_pref_dirs)
if [ -n "$VERSION" ] && ! printf '%s\n' "$DIRS" | grep -qxF "$ROAMING/$VERSION"; then
    mkdir -p "$ROAMING/$VERSION"
    DIRS=$(printf '%s\n%s\n' "$DIRS" "$ROAMING/$VERSION")
fi

if [ "$(aegnux_audio_plan)" = nodevice ]; then NO_DEVICES=true; else NO_DEVICES=false; fi

printf '%s\n' "$DIRS" | while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ "${AEGNUX_DIRECTX_DISPLAY:-0}" != 1 ]; then
        set_db_pref "$dir/Debug Database.txt" DS.DisableDirectXDisplay true false
    fi
    if [ "$NO_DEVICES" = true ] || grep -q "^dvaaudiodevice\.ForceNoDevices$TAB" "$dir/Debug Database.txt" 2> /dev/null; then
        set_db_pref "$dir/Debug Database.txt" dvaaudiodevice.ForceNoDevices "$NO_DEVICES" false
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