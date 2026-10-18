#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Shared settings for the aegnux scripts.
#
# Each value is taken from the environment if it is set there, otherwise from the
# config file (default ~/.config/aegnux/aegnux.conf, plain KEY=value lines, written by
# build_dzn.sh), otherwise from the defaults below, which follow the aegnux layout.

AEGNUX_CONFIG="${AEGNUX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/aegnux/aegnux.conf}"
if [ -f "$AEGNUX_CONFIG" ]; then
    while IFS='=' read -r _aegnux_key _aegnux_value; do
        case "$_aegnux_key" in ''|'#'*|*[!A-Za-z0-9_]*) continue ;; esac
        if ! declare -p "$_aegnux_key" > /dev/null 2>&1; then
            export "$_aegnux_key=$_aegnux_value"
        fi
    done < "$AEGNUX_CONFIG"
    unset _aegnux_key _aegnux_value
fi

AEGNUX_HOME="${AEGNUX_HOME:-$HOME/.local/share/aegnux}"
WINE_BIN_DIR="${WINE_BIN_DIR:-$AEGNUX_HOME/runner/bin}"
WINEPREFIX="${WINEPREFIX:-$AEGNUX_HOME/wineprefix}"
AE_DIR="${AE_DIR:-$AEGNUX_HOME/AE}"
MESA_SRC="${MESA_SRC:-$HOME/src/mesa-25.2.8}"
MESA_BUILD="${MESA_BUILD:-$MESA_SRC/build}"
DZN_PREFIX="${DZN_PREFIX:-$AEGNUX_HOME/dzn}"
AEGNUX_LAYER_DIR="${AEGNUX_LAYER_DIR:-$AEGNUX_HOME/layer}"
AEGNUX_LOG_DIR="${AEGNUX_LOG_DIR:-$AEGNUX_HOME/logs}"
AEGNUX_TEST_DIR="${AEGNUX_TEST_DIR:-$AEGNUX_HOME/tests}"
# Vulkan driver: auto (dzn under WSL, the host's own driver elsewhere), dzn or system.
AEGNUX_VULKAN="${AEGNUX_VULKAN:-auto}"

export AEGNUX_CONFIG AEGNUX_HOME WINE_BIN_DIR WINEPREFIX AE_DIR MESA_SRC MESA_BUILD
export DZN_PREFIX AEGNUX_LAYER_DIR AEGNUX_LOG_DIR AEGNUX_TEST_DIR AEGNUX_VULKAN

# True under WSL2, where Direct3D 12 is reachable through /dev/dxg.
is_wsl() {
    grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null || [ -e /dev/dxg ]
}

# Prints "dzn" or "system".
aegnux_vulkan_mode() {
    case "$AEGNUX_VULKAN" in
        dzn|system) echo "$AEGNUX_VULKAN" ;;
        *) if is_wsl; then echo dzn; else echo system; fi ;;
    esac
}

aegnux_dzn_icd() {
    echo "$DZN_PREFIX/share/vulkan/icd.d/dzn_icd.x86_64.json"
}

# Wine names the user folder of the prefix after the Unix login name.
aegnux_win_user() {
    id -un
}

aegnux_ae_roaming() {
    echo "$WINEPREFIX/drive_c/users/$(aegnux_win_user)/AppData/Roaming/Adobe/After Effects"
}

# major.minor of the installed AE (the name of its preferences folder, e.g. 24.6),
# read from AMT/application.xml. Prints nothing if it cannot be found.
aegnux_ae_version() {
    local xml="$AE_DIR/AMT/application.xml"
    if [ -f "$xml" ]; then
        sed -n 's/.*<Data key="ProductVersion">\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$xml" | head -n 1
    fi
}

# Prints each AE preferences folder in the prefix, one per AE version (24.6, ...).
aegnux_ae_pref_dirs() {
    local d
    for d in "$(aegnux_ae_roaming)"/[0-9]*.[0-9]*/; do
        if [ -d "$d" ]; then printf '%s\n' "${d%/}"; fi
    done
}

aegnux_env() {
    export PATH="$WINE_BIN_DIR:$PATH"
    export WINEPREFIX
    local overrides="mscoree,mshtml="
    # AEGNUX_DISABLE_CUDA=1 hides CUDA from AE: software rendering, and AE then
    # reports Advanced 3D as unsupported.
    if [ "${AEGNUX_DISABLE_CUDA:-0}" = 1 ]; then overrides="$overrides;nvcuda,nvcuvid=d"; fi
    if [ -n "${AEGNUX_EXTRA_OVERRIDES:-}" ]; then overrides="$overrides;$AEGNUX_EXTRA_OVERRIDES"; fi
    export WINEDLLOVERRIDES="$overrides"
    export WINEDEBUG="${AEGNUX_WINEDEBUG:-err+module,err+d3d,err+dxgi,err+vulkan,warn+d3d,err+seh}"
    if [ "$(aegnux_vulkan_mode)" = dzn ]; then
        export VK_ICD_FILENAMES="$(aegnux_dzn_icd)"
        # Optional apiVersion layer. Patch 04 made it unnecessary in all tests.
        if [ "${AEGNUX_APIVER_LAYER:-0}" = 1 ]; then
            export VK_LAYER_PATH="$AEGNUX_LAYER_DIR"
            export VK_LOADER_LAYERS_ENABLE=VK_LAYER_AEGNUX_apiversion
        fi
    fi
    # Under WSL, OpenGL must go through Mesa's D3D12 Gallium driver; without it the
    # UI falls back to llvmpipe (CPU). Native hosts keep their own GL driver.
    if is_wsl && [ -z "${GALLIUM_DRIVER:-}" ]; then export GALLIUM_DRIVER=d3d12; fi
}

# Prints an install command for generic package names on this distribution. The
# names are hints; check them against your release.
aegnux_pkg_hint() {
    local family="" out p
    if [ -r /etc/os-release ]; then
        family=$(. /etc/os-release; echo " ${ID:-} ${ID_LIKE:-} ")
    fi
    case "$family" in
        *" debian "*|*" ubuntu "*) out="sudo apt install"; family=apt ;;
        *" fedora "*|*" rhel "*|*" centos "*) out="sudo dnf install"; family=dnf ;;
        *" arch "*) out="sudo pacman -S --needed"; family=pacman ;;
        *" suse "*|*" opensuse "*) out="sudo zypper install"; family=zypper ;;
        *) out="install (names may differ):"; family=other ;;
    esac
    for p in "$@"; do
        case "$family:$p" in
            apt:gcc) p=build-essential ;;
            pacman:gcc) p=base-devel ;;
            apt:ninja|dnf:ninja) p=ninja-build ;;
            pacman:python3-mako) p=python-mako ;;
            zypper:python3-mako) p=python3-Mako ;;
            dnf:pkg-config|pacman:pkg-config|zypper:pkg-config) p=pkgconf ;;
            dnf:x11-utils) p=xorg-x11-utils ;;
            pacman:x11-utils) p=xorg-xwininfo ;;
            zypper:x11-utils) p=xwininfo ;;
            dnf:xvfb|zypper:xvfb) p=xorg-x11-server-Xvfb ;;
            pacman:xvfb) p=xorg-server-xvfb ;;
            dnf:libx11-dev|zypper:libx11-dev) p=libX11-devel ;;
            pacman:libx11-dev) p=libx11 ;;
            apt:mingw-gcc) p=gcc-mingw-w64-x86-64 ;;
            dnf:mingw-gcc) p=mingw64-gcc ;;
            pacman:mingw-gcc) p=mingw-w64-gcc ;;
            zypper:mingw-gcc) p=mingw64-cross-gcc ;;
        esac
        out="$out $p"
    done
    echo "$out"
}