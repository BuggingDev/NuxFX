#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Shared settings for the aegnux scripts.
#
# Each value is taken from the environment if it is set there, otherwise from the
# config file (default ~/.config/aegnux/aegnux.conf, plain KEY=value lines, written by
# build_dzn.sh), otherwise from the defaults below, which follow the aegnux layout.

AEGNUX_CONFIG="${AEGNUX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/aegnux/aegnux.conf}"
# Keys read from the config file. Other lines are ignored; doctor.sh reports them.
AEGNUX_CONFIG_KEYS="AEGNUX_HOME AEGNUX_LAYER_DIR AEGNUX_LOG_DIR AEGNUX_TEST_DIR AEGNUX_VULKAN AEGNUX_DISABLE_CUDA AEGNUX_DIRECTX_DISPLAY AEGNUX_GL_PREFIX AEGNUX_SYSTEM_GL AEGNUX_REP_MOVSB AEGNUX_HIDE_HOME_SCREEN AEGNUX_COACHMARKS AEGNUX_EXTRA_OVERRIDES AEGNUX_WINEDEBUG AEGNUX_APIVER_LAYER AEGNUX_WAYLAND WINE_BIN_DIR WINEPREFIX AE_DIR MESA_SRC MESA_BUILD DZN_PREFIX AE_VERSION"
if [ -f "$AEGNUX_CONFIG" ]; then
    while IFS= read -r _aegnux_line || [ -n "$_aegnux_line" ]; do
        _aegnux_line=${_aegnux_line%$'\r'}
        case "$_aegnux_line" in *=*) ;; *) continue ;; esac
        _aegnux_key=${_aegnux_line%%=*}
        _aegnux_value=${_aegnux_line#*=}
        case " $AEGNUX_CONFIG_KEYS " in *" $_aegnux_key "*) ;; *) continue ;; esac
        case "$_aegnux_value" in
            \"*\") _aegnux_value=${_aegnux_value#\"}; _aegnux_value=${_aegnux_value%\"} ;;
            \'*\') _aegnux_value=${_aegnux_value#\'}; _aegnux_value=${_aegnux_value%\'} ;;
        esac
        if [ -z "${!_aegnux_key+x}" ]; then export "$_aegnux_key=$_aegnux_value"; fi
    done < "$AEGNUX_CONFIG"
    unset _aegnux_line _aegnux_key _aegnux_value
fi

AEGNUX_HOME="${AEGNUX_HOME:-$HOME/.local/share/aegnux}"
WINE_BIN_DIR="${WINE_BIN_DIR:-$AEGNUX_HOME/runner/bin}"
WINEPREFIX="${WINEPREFIX:-$AEGNUX_HOME/wineprefix}"
AE_DIR="${AE_DIR:-$AEGNUX_HOME/AE}"
MESA_SRC="${MESA_SRC:-$HOME/src/mesa-25.2.8}"
MESA_BUILD="${MESA_BUILD:-$MESA_SRC/build}"
DZN_PREFIX="${DZN_PREFIX:-$AEGNUX_HOME/dzn}"
# Mesa's EGL and Direct3D 12 OpenGL driver that build_gl.sh installs (WSL2).
AEGNUX_GL_PREFIX="${AEGNUX_GL_PREFIX:-$AEGNUX_HOME/mesa-gl}"
AEGNUX_LAYER_DIR="${AEGNUX_LAYER_DIR:-$AEGNUX_HOME/layer}"
AEGNUX_LOG_DIR="${AEGNUX_LOG_DIR:-$AEGNUX_HOME/logs}"
AEGNUX_TEST_DIR="${AEGNUX_TEST_DIR:-$AEGNUX_HOME/tests}"
# Vulkan driver: auto (dzn under WSL, the host's own driver elsewhere), dzn or system.
AEGNUX_VULKAN="${AEGNUX_VULKAN:-auto}"

export AEGNUX_CONFIG AEGNUX_HOME WINE_BIN_DIR WINEPREFIX AE_DIR MESA_SRC MESA_BUILD
export DZN_PREFIX AEGNUX_GL_PREFIX AEGNUX_LAYER_DIR AEGNUX_LOG_DIR AEGNUX_TEST_DIR AEGNUX_VULKAN

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

# The display server Wine talks to: "x11" or "wayland". After Effects was verified with Wine's
# X11 driver, which on a Wayland desktop runs through XWayland (GNOME, KDE Plasma, sway and the
# others start it). Wine's own Wayland driver is only used when asked for or when there is no X
# display at all.
#   AEGNUX_WAYLAND=auto (default)  x11 when DISPLAY is set, wayland when only WAYLAND_DISPLAY is set
#   AEGNUX_WAYLAND=0               always x11
#   AEGNUX_WAYLAND=1               always wayland (experimental)
aegnux_wine_driver() {
    case "${AEGNUX_WAYLAND:-auto}" in
        1|wayland) echo wayland ;;
        0|x11) echo x11 ;;
        *)
            if [ -n "${DISPLAY:-}" ]; then
                echo x11
            elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
                echo wayland
            else
                echo x11
            fi
            ;;
    esac
}

# Prints the libwayland-client symbols that Wine's Wayland driver needs and the installed library
# lacks (nothing when it can load). The runner is built against libwayland 1.23 or newer and calls
# wl_display_create_queue_with_name; with an older libwayland (Ubuntu 24.04 has 1.22) the driver does
# not load and Wine says "no driver could be loaded". The X11 driver is not affected.
aegnux_wayland_missing_symbols() {
    local so="$WINE_BIN_DIR/../lib/wine/x86_64-unix/winewayland.so"
    [ -f "$so" ] || return 0
    command -v ldd > /dev/null 2>&1 || return 0
    ldd -r "$so" 2>&1 | sed -n 's/^undefined symbol: \(wl_[A-Za-z0-9_]*\).*/\1/p' | sort -u | paste -sd ' ' -
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

# PIDs of this user's processes whose command line matches the pgrep pattern $1 and whose
# environment has this prefix's WINEPREFIX. Other prefixes and other programs do not match.
aegnux_prefix_pids() {
    local pid
    for pid in $(pgrep -u "$(id -u)" -f "$1" 2> /dev/null); do
        if tr '\0' '\n' < "/proc/$pid/environ" 2> /dev/null | grep -qxF "WINEPREFIX=$WINEPREFIX"; then
            echo "$pid"
        fi
    done
}

aegnux_env() {
    export PATH="$WINE_BIN_DIR:$PATH"
    export WINEPREFIX
    local overrides="mscoree,mshtml="
    # AEGNUX_DISABLE_CUDA=1: AE gets no CUDA (nvcuda and nvcuvid are disabled), and dzn does
    # not query CUDA (DZN_DEBUG=nocudauuid, patch 18). AE then renders in software and
    # reports Advanced 3D as unsupported.
    if [ "${AEGNUX_DISABLE_CUDA:-0}" = 1 ]; then
        overrides="$overrides;nvcuda,nvcuvid=d"
        case ",${DZN_DEBUG:-}," in
            *,nocudauuid,*) ;;
            *) export DZN_DEBUG="${DZN_DEBUG:+$DZN_DEBUG,}nocudauuid" ;;
        esac
    fi
    if [ -n "${AEGNUX_EXTRA_OVERRIDES:-}" ]; then overrides="$overrides;$AEGNUX_EXTRA_OVERRIDES"; fi
    # Overrides already set in the caller's environment come last, so they take precedence.
    if [ -n "${WINEDLLOVERRIDES:-}" ]; then overrides="$overrides;$WINEDLLOVERRIDES"; fi
    export WINEDLLOVERRIDES="$overrides"
    export WINEDEBUG="${WINEDEBUG:-${AEGNUX_WINEDEBUG:-err+module,err+d3d,err+dxgi,err+vulkan,warn+d3d,err+seh}}"
    # With the X11 driver the Wayland socket is hidden from Wine and from the programs it starts:
    # that is the setup the tests ran in, and a Wine that sees both prefers its Wayland driver.
    if [ "$(aegnux_wine_driver)" = x11 ]; then unset WAYLAND_DISPLAY; fi
    if [ "$(aegnux_vulkan_mode)" = dzn ]; then
        export VK_ICD_FILENAMES="$(aegnux_dzn_icd)"
        # DXVK 3.0.1 refuses a device without storageBuffer8BitAccess, and dzn reports it
        # only when this driconf option is on. Without it DXVK fails to start ("No adapters
        # found") and After Effects shows a black window. Mesa reads *.conf from here as well
        # as from ~/.config/drirc.
        local drirc_dir="$DZN_PREFIX/share/drirc.d"
        if [ -d "$DZN_PREFIX" ]; then
            mkdir -p "$drirc_dir" 2> /dev/null
            if [ ! -f "$drirc_dir/50-nuxfx-dzn.conf" ]; then
                cat > "$drirc_dir/50-nuxfx-dzn.conf" 2> /dev/null <<'EOF'
<driconf>
    <device driver="dzn">
        <application name="Default">
            <option name="dzn_enable_8bit_loads_stores" value="true" />
        </application>
    </device>
</driconf>
EOF
            fi
            if [ ! -f "$drirc_dir/00-mesa-defaults.conf" ] && [ -f "$MESA_SRC/src/util/00-mesa-defaults.conf" ]; then
                cp "$MESA_SRC/src/util/00-mesa-defaults.conf" "$drirc_dir/" 2> /dev/null
            fi
            export DRIRC_CONFIGDIR="$drirc_dir"
        fi
        # Optional apiVersion layer. Patch 04 made it unnecessary in all tests.
        if [ "${AEGNUX_APIVER_LAYER:-0}" = 1 ]; then
            export VK_LAYER_PATH="$AEGNUX_LAYER_DIR"
            export VK_LOADER_LAYERS_ENABLE=VK_LAYER_AEGNUX_apiversion
        fi
    fi
    # Under WSL, OpenGL must go through Mesa's D3D12 Gallium driver; without it the
    # UI falls back to llvmpipe (CPU). Native hosts keep their own GL driver.
    if is_wsl && [ -z "${GALLIUM_DRIVER:-}" ]; then export GALLIUM_DRIVER=d3d12; fi
    # Wine draws After Effects' Composition panel with OpenGL through EGL. The distribution's
    # Mesa is not used when build_gl.sh installed Mesa 25.2.8's EGL and d3d12 driver: with
    # Mesa 26 (Arch Linux, Fedora 44) the panel stayed empty, and the Mesa of every
    # distribution differs. The private libEGL.so.1 comes first in the library path.
    # AEGNUX_SYSTEM_GL=1 keeps the distribution's OpenGL.
    if is_wsl && [ "${AEGNUX_SYSTEM_GL:-0}" != 1 ] && [ -f "$AEGNUX_GL_PREFIX/lib/libEGL.so.1" ]; then
        case ":${LD_LIBRARY_PATH:-}:" in
            *":$AEGNUX_GL_PREFIX/lib:"*) ;;
            *) export LD_LIBRARY_PATH="$AEGNUX_GL_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
        esac
    fi
    # Wine turns every EGL device into a GPU. Besides the real one, Mesa lists WSLg's "vgem"
    # render node, and when the user can open /dev/dri/card0 (the video group on Arch Linux) it
    # starts that device too. Wine then reports a second NVIDIA adapter, "D3D12 (NVIDIA ...)",
    # that After Effects' System Compatibility Report rejects (a dialog on every start that
    # waits for a click). Naming the driver stops Mesa from building a screen for vgem, so the
    # device is skipped; the display's own EGL path (software winsys) does not change.
    if is_wsl && [ -z "${MESA_LOADER_DRIVER_OVERRIDE:-}" ]; then export MESA_LOADER_DRIVER_OVERRIDE=d3d12; fi
    # After Effects shows every frame with glTexSubImage2D, and Mesa's d3d12 driver copies the
    # frame into its upload buffer one row (about 5 KB) at a time. From 4 KB up glibc's memcpy
    # uses "rep movsb", and on the shared-memory mappings of the Direct3D 12 route that
    # instruction runs at about 45 MB/s (vector loops: about 2 GB/s). RAM preview then showed
    # about 7 frames a second, a fifth of real time. Raising glibc's rep movsb threshold keeps
    # memcpy on the vector loops. AEGNUX_REP_MOVSB=1 keeps glibc's default.
    if is_wsl && [ "${AEGNUX_REP_MOVSB:-0}" != 1 ]; then
        case ":${GLIBC_TUNABLES:-}:" in
            *:glibc.cpu.x86_rep_movsb_threshold=*) ;;
            *) export GLIBC_TUNABLES="${GLIBC_TUNABLES:+$GLIBC_TUNABLES:}glibc.cpu.x86_rep_movsb_threshold=0x40000000" ;;
        esac
    fi
}

# Package manager family of this distribution: apt, dnf, pacman, zypper or other.
aegnux_family() {
    local family=""
    if [ -r /etc/os-release ]; then
        family=$(. /etc/os-release; echo " ${ID:-} ${ID_LIKE:-} ")
    fi
    case "$family" in
        *" debian "*|*" ubuntu "*) echo apt ;;
        *" fedora "*|*" rhel "*|*" centos "*) echo dnf ;;
        *" arch "*) echo pacman ;;
        *" suse "*|*" opensuse "*) echo zypper ;;
        *) echo other ;;
    esac
}

# Shared libraries the Wine runner opens with dlopen at run time. Wine does not stop when one
# is missing, it switches the feature off. Without libXcomposite.so.1 it cannot show OpenGL
# child windows, so After Effects' Composition panel stays black although the frames render.
# (The names were read from the runner: strings on winex11.so and the other unix libraries.)
AEGNUX_WINE_SONAMES="libX11.so.6 libXext.so.6 libXi.so.6 libXrandr.so.2 libXrender.so.1 libXfixes.so.3 libXcursor.so.1 libXcomposite.so.1 libXinerama.so.1 libXxf86vm.so.1 libxkbcommon.so.0 libxkbregistry.so.0 libfreetype.so.6 libfontconfig.so.1 libgnutls.so.30 libEGL.so.1 libGL.so.1"

# Prints the sonames of AEGNUX_WINE_SONAMES that the dynamic linker does not know. ldconfig
# lives in /sbin on Debian, which is not in an ordinary user's PATH.
aegnux_wine_libs_missing() {
    local ld cache s
    ld=$(command -v ldconfig 2> /dev/null || echo /sbin/ldconfig)
    cache=$("$ld" -p 2> /dev/null) || return 0
    for s in $AEGNUX_WINE_SONAMES; do
        printf '%s\n' "$cache" | grep -q "^[[:space:]]*$s ([^)]*x86-64" || echo "$s"
    done
}

# Prints the package that provides shared library $1 on this distribution. dnf and zypper
# install a package by the library it provides, so only apt and pacman need a table.
aegnux_soname_pkg() {
    local s=$1
    case "$(aegnux_family):$s" in
        apt:libX11.so.6) echo libx11-6 ;;
        apt:libXext.so.6) echo libxext6 ;;
        apt:libXi.so.6) echo libxi6 ;;
        apt:libXrandr.so.2) echo libxrandr2 ;;
        apt:libXrender.so.1) echo libxrender1 ;;
        apt:libXfixes.so.3) echo libxfixes3 ;;
        apt:libXcursor.so.1) echo libxcursor1 ;;
        apt:libXcomposite.so.1) echo libxcomposite1 ;;
        apt:libXinerama.so.1) echo libxinerama1 ;;
        apt:libXxf86vm.so.1) echo libxxf86vm1 ;;
        apt:libxkbcommon.so.0) echo libxkbcommon0 ;;
        apt:libxkbregistry.so.0) echo libxkbregistry0 ;;
        apt:libfreetype.so.6) echo libfreetype6 ;;
        apt:libfontconfig.so.1) echo libfontconfig1 ;;
        apt:libgnutls.so.30) echo libgnutls30 ;;
        apt:libEGL.so.1) echo libegl1 ;;
        apt:libGL.so.1) echo libgl1 ;;
        pacman:libX11.so.6) echo libx11 ;;
        pacman:libXext.so.6) echo libxext ;;
        pacman:libXi.so.6) echo libxi ;;
        pacman:libXrandr.so.2) echo libxrandr ;;
        pacman:libXrender.so.1) echo libxrender ;;
        pacman:libXfixes.so.3) echo libxfixes ;;
        pacman:libXcursor.so.1) echo libxcursor ;;
        pacman:libXcomposite.so.1) echo libxcomposite ;;
        pacman:libXinerama.so.1) echo libxinerama ;;
        pacman:libXxf86vm.so.1) echo libxxf86vm ;;
        pacman:libxkbcommon.so.0|pacman:libxkbregistry.so.0) echo libxkbcommon ;;
        pacman:libfreetype.so.6) echo freetype2 ;;
        pacman:libfontconfig.so.1) echo fontconfig ;;
        pacman:libgnutls.so.30) echo gnutls ;;
        pacman:libEGL.so.1|pacman:libGL.so.1) echo libglvnd ;;
        dnf:*|zypper:*) echo "'$s()(64bit)'" ;;
        *) echo "$s" ;;
    esac
}

# openSUSE ships several Python versions side by side, and a capability such as
# python3dist(packaging) can resolve to the module of another version than the python3 that
# runs the build. Prints the package prefix of the python3 in PATH (python313).
aegnux_suse_python() {
    python3 -c 'import sys; print("python%d%d" % sys.version_info[:2])' 2> /dev/null || echo python3
}

# Prints an install command for generic package names on this distribution. The
# names are hints; check them against your release. A name that looks like a shared
# library (libXcomposite.so.1) is turned into the package that provides it.
aegnux_pkg_hint() {
    local family out p
    family=$(aegnux_family)
    case "$family" in
        apt) out="sudo apt install" ;;
        dnf) out="sudo dnf install" ;;
        pacman) out="sudo pacman -S --needed" ;;
        zypper) out="sudo zypper install" ;;
        *) out="install (names may differ):" ;;
    esac
    for p in "$@"; do
        case "$p" in lib*.so.*) p=$(aegnux_soname_pkg "$p") ;; esac
        case "$family:$p" in
            apt:gcc|apt:gcc-c++) p=build-essential ;;
            pacman:gcc) p=base-devel ;;
            pacman:gcc-c++) p=gcc ;;
            apt:mesa-dri) p=libgl1-mesa-dri ;;
            dnf:mesa-dri) p=mesa-dri-drivers ;;
            pacman:mesa-dri) p=mesa ;;
            zypper:mesa-dri) p=Mesa-dri ;;
            apt:vulkan-loader|zypper:vulkan-loader) p=libvulkan1 ;;
            pacman:vulkan-loader) p=vulkan-icd-loader ;;
            apt:xz) p=xz-utils ;;
            apt:awk|dnf:awk|pacman:awk|zypper:awk) p=gawk ;;
            apt:which) p=debianutils ;;
            dnf:procps|pacman:procps) p=procps-ng ;;
            pacman:pipx) p=python-pipx ;;
            apt:ninja|dnf:ninja) p=ninja-build ;;
            pacman:python3-mako) p=python-mako ;;
            zypper:python3-mako) p="$(aegnux_suse_python)-Mako" ;;
            dnf:pkg-config|pacman:pkg-config|zypper:pkg-config) p=pkgconf ;;
            dnf:x11-utils) p=xwininfo ;;
            pacman:x11-utils) p=xorg-xwininfo ;;
            zypper:x11-utils) p=xwininfo ;;
            dnf:xvfb) p=xorg-x11-server-Xvfb ;;
            zypper:xvfb) p=xorg-x11-server-Xvfb ;;
            pacman:xvfb) p=xorg-server-xvfb ;;
            dnf:libx11-dev|zypper:libx11-dev) p=libX11-devel ;;
            pacman:libx11-dev) p=libx11 ;;
            apt:glslangValidator) p=glslang-tools ;;
            dnf:glslangValidator|pacman:glslangValidator) p=glslang ;;
            zypper:glslangValidator) p=glslang-devel ;;
            apt:libvulkan-dev) ;;
            dnf:libvulkan-dev) p=vulkan-loader-devel ;;
            pacman:libvulkan-dev) p="vulkan-headers vulkan-icd-loader" ;;
            zypper:libvulkan-dev) p=vulkan-devel ;;
            apt:mingw-gcc) p=gcc-mingw-w64-x86-64 ;;
            dnf:mingw-gcc) p=mingw64-gcc ;;
            pacman:mingw-gcc) p=mingw-w64-gcc ;;
            zypper:mingw-gcc) p=mingw64-cross-gcc ;;
            apt:xwayland) ;;
            dnf:xwayland) p=xorg-x11-server-Xwayland ;;
            pacman:xwayland) p=xorg-xwayland ;;
            zypper:xwayland) p=xwayland ;;
        esac
        case " $out " in *" $p "*) ;; *) out="$out $p" ;; esac
    done
    echo "$out"
}


# Development packages the dzn and OpenGL builds need besides the build tools (the pkg-config
# modules and programs Mesa 25.2.8 configures with). The names were checked by installing
# them on fresh Ubuntu 24.04, Debian 13, Fedora 44 and Arch Linux images; openSUSE gets
# capabilities (pkgconfig(...), file paths) instead of package names.
aegnux_mesa_dev_hint() {
    local family="" py
    if [ -r /etc/os-release ]; then
        family=$(. /etc/os-release; echo " ${ID:-} ${ID_LIKE:-} ")
    fi
    case "$family" in
        *" debian "*|*" ubuntu "*)
            echo "sudo apt install bison flex glslang-tools python3-yaml python3-packaging libdrm-dev libexpat1-dev zlib1g-dev libelf-dev libzstd-dev libwayland-dev wayland-protocols libx11-xcb-dev libxcb1-dev libxcb-dri3-dev libxcb-present-dev libxcb-randr0-dev libxcb-shm0-dev libxcb-sync-dev libxcb-xfixes0-dev libxcb-keysyms1-dev libxrandr-dev libxshmfence-dev spirv-tools" ;;
        *" fedora "*|*" rhel "*|*" centos "*)
            echo "sudo dnf install bison flex glslang python3-pyyaml python3-packaging libdrm-devel expat-devel zlib-devel libzstd-devel elfutils-libelf-devel wayland-devel wayland-protocols-devel libxcb-devel libX11-devel libXrandr-devel libxshmfence-devel xcb-util-keysyms-devel spirv-tools-devel" ;;
        *" arch "*)
            echo "sudo pacman -S --needed bison flex glslang python-yaml python-packaging libdrm expat zlib zstd libelf wayland wayland-protocols libx11 libxcb libxrandr libxshmfence xcb-util-keysyms spirv-tools" ;;
        *" suse "*|*" opensuse "*)
            # zypper installs by capability, which is more reliable than guessing package names;
            # the Python modules need the prefix of the python3 in use (see aegnux_suse_python)
            py=$(aegnux_suse_python)
            echo "sudo zypper install bison flex glslang-devel wayland-devel $py-PyYAML $py-packaging 'pkgconfig(libdrm)' 'pkgconfig(expat)' 'pkgconfig(zlib)' 'pkgconfig(libzstd)' 'pkgconfig(libelf)' 'pkgconfig(wayland-client)' 'pkgconfig(wayland-server)' 'pkgconfig(wayland-protocols)' 'pkgconfig(x11-xcb)' 'pkgconfig(xcb)' 'pkgconfig(xcb-dri3)' 'pkgconfig(xcb-present)' 'pkgconfig(xcb-randr)' 'pkgconfig(xcb-shm)' 'pkgconfig(xcb-sync)' 'pkgconfig(xcb-xfixes)' 'pkgconfig(xcb-keysyms)' 'pkgconfig(xrandr)' 'pkgconfig(xshmfence)' 'pkgconfig(SPIRV-Tools)'" ;;
        *) echo "install the development packages for: bison flex glslangValidator wayland-scanner libdrm expat zlib zstd libelf wayland x11-xcb xcb xcb-dri3 xcb-present xcb-randr xcb-shm xcb-sync xcb-xfixes xcb-keysyms xrandr xshmfence SPIRV-Tools" ;;
    esac
}

# Prints what the dzn build is missing, one item per line: programs, python modules, a
# meson that is too old (Mesa 25.2.8 needs 1.4 or newer) and pkg-config modules.
aegnux_build_missing() {
    local t m ver
    for t in meson ninja pkg-config git python3 bison flex glslangValidator wayland-scanner; do
        if ! command -v "$t" > /dev/null 2>&1; then if [ "$t" = meson ]; then echo "meson (1.4 or newer; install it with: pipx install meson)"; else echo "$t"; fi; fi
    done
    command -v cc > /dev/null 2>&1 || echo gcc
    command -v c++ > /dev/null 2>&1 || echo "g++ (the C++ compiler: gcc-c++ on Fedora and openSUSE)"
    for m in mako yaml packaging; do
        python3 -c "import $m" 2> /dev/null || echo "python3 module $m"
    done
    if command -v meson > /dev/null 2>&1; then
        ver=$(meson --version 2> /dev/null)
        case "$ver" in
            0.*|1.[0-3]|1.[0-3].*) echo "meson $ver is too old (1.4 or newer; install it with: pipx install meson)" ;;
        esac
    fi
    if command -v pkg-config > /dev/null 2>&1; then
        for m in libdrm expat zlib libzstd libelf wayland-client wayland-server wayland-protocols x11-xcb xcb xcb-dri3 xcb-present xcb-randr xcb-shm xcb-sync xcb-xfixes xcb-keysyms xrandr xshmfence SPIRV-Tools; do
            pkg-config --exists "$m" 2> /dev/null || echo "pkg-config module $m"
        done
    fi
}
