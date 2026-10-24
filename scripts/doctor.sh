#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Checks the host, the Wine prefix and the After Effects setup, and prints what is
# missing with an install hint for this distribution. Read-only: changes nothing.
#
#   doctor.sh           runtime checks
#   doctor.sh --build   also checks the tools that build_dzn.sh needs
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"

FAILS=0
WARNS=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
have() { command -v "$1" > /dev/null 2>&1; }

# sha256 of the DXVK 3.0.1 / vkd3d-proton 3.0.1 DLLs everything was tested with.
TESTED_DLLS="dxgi.dll 5270db8eca25a0bc85d5aad623feaae28fa2d655ae138a47fc10c72e4ef5d899
d3d11.dll 411e198cad14d1c726b6f395cf2b9a477b5df6b8b05de9b26a5ec1b615291be6
d3d12.dll aed51497c0efa76c9ffc30386ff0957197824cd4734ce64b4e962d3551fba43c
d3d12core.dll 68b8bc7b32f9b1b1b0526e9e2e769731dd8da9af0f2b40f76012385b9d5721df"

echo "Host"
if [ -r /etc/os-release ]; then ok "distribution: $(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"; fi
ok "kernel: $(uname -r)"
MODE=$(aegnux_vulkan_mode)
if is_wsl; then
    ok "WSL2 (Vulkan through dzn, OpenGL through Mesa's D3D12 driver)"
    if [ -e /dev/dxg ]; then ok "/dev/dxg present"; else fail "/dev/dxg missing: Direct3D 12 is not reachable (update WSL and the Windows GPU driver)"; fi
else
    ok "native Linux (the host's own Vulkan and OpenGL drivers are used; dzn is not needed)"
fi
ok "Vulkan driver mode: $MODE"
if [ -e /dev/ntsync ]; then ok "/dev/ntsync present"; else warn "/dev/ntsync missing: Wine's NTsync is not used on this kernel"; fi
ok "ptrace_scope: $(cat /proc/sys/kernel/yama/ptrace_scope 2> /dev/null || echo unknown) (1: a debugger can attach only to its own child processes)"
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    ok "display: ${DISPLAY:-} ${WAYLAND_DISPLAY:-}"
else
    fail "neither DISPLAY nor WAYLAND_DISPLAY is set (start from a desktop session or WSLg)"
fi

echo "Wine and After Effects"
if [ -f "$AEGNUX_CONFIG" ]; then
    UNKNOWN=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$AEGNUX_CONFIG" | while IFS= read -r k; do
        case " $AEGNUX_CONFIG_KEYS " in *" $k "*) ;; *) echo "$k" ;; esac
    done | tr '\n' ' ')
    if [ -n "$UNKNOWN" ]; then warn "aegnux.conf keys that are ignored: $UNKNOWN"; else ok "aegnux.conf: all keys are used"; fi
fi
if [ -x "$WINE_BIN_DIR/wine" ]; then
    ok "Wine runner: $("$WINE_BIN_DIR/wine" --version 2>/dev/null) (tested: wine-11.12 TkG)"
else
    fail "no Wine runner at $WINE_BIN_DIR (set WINE_BIN_DIR)"
fi
if [ -f "$WINEPREFIX/system.reg" ]; then ok "prefix: $WINEPREFIX"; else fail "no Wine prefix at $WINEPREFIX (set WINEPREFIX)"; fi
if grep -aq '^"RelayExclude"' "$WINEPREFIX/user.reg" 2> /dev/null; then warn "the prefix has a RelayExclude list (wine.inf): relay traces hide the critical-section calls; remove it from HKCU\Software\Wine\Debug to see them"; fi
if [ -f "$AE_DIR/AfterFX.exe" ]; then
    ok "After Effects: $AE_DIR (version ${AE_VERSION:-$(aegnux_ae_version)}; tested: 24.6)"
else
    fail "AfterFX.exe not found in $AE_DIR (set AE_DIR)"
fi

echo "Vulkan"
if [ "$MODE" = dzn ]; then
    ICD=$(aegnux_dzn_icd)
    if [ -f "$ICD" ]; then
        LIB=$(sed -n 's/.*"library_path": *"\([^"]*\)".*/\1/p' "$ICD")
        if [ -f "$LIB" ]; then
            ok "dzn: $LIB"
            # Patch 21 names its memfd "dzn-timeline-semaphore"; the string is in the library.
            if grep -aq 'dzn-timeline-semaphore' "$LIB"; then
                ok "dzn has patch 21 (shared timeline semaphores)"
            else
                warn "dzn lacks patch 21 (shared timeline semaphores): After Effects crashes when the viewer shows an Advanced 3D comp; rebuild with scripts/build_dzn.sh"
            fi
        else
            fail "$ICD points to a missing library: $LIB"
        fi
        API=$(sed -n 's/.*"api_version": *"\([^"]*\)".*/\1/p' "$ICD")
        case "$API" in
            1.3.*|1.4.*|1.[5-9].*) ok "dzn ICD api_version: $API" ;;
            "") warn "dzn ICD has no api_version (rebuild with scripts/build_dzn.sh)" ;;
            *) warn "dzn ICD api_version is $API, but dzn reports 1.3 (patch 04); rebuild with scripts/build_dzn.sh" ;;
        esac
    else
        fail "dzn ICD missing: $ICD (run scripts/build_dzn.sh, or set DZN_PREFIX)"
    fi
    for l in /usr/lib/wsl/lib/libd3d12.so /usr/lib/wsl/lib/libdxcore.so; do
        if [ -e "$l" ]; then ok "$l"; else fail "$l missing (WSL Direct3D 12 runtime)"; fi
    done
elif have vulkaninfo; then
    DEVS=$(vulkaninfo --summary 2>/dev/null | sed -n 's/^[[:space:]]*deviceName[[:space:]]*=[[:space:]]*//p')
    if [ -z "$DEVS" ]; then
        fail "no Vulkan device found; install the Vulkan driver for your GPU"
    else
        printf '%s\n' "$DEVS" | while IFS= read -r d; do ok "Vulkan device: $d"; done
        if ! printf '%s\n' "$DEVS" | grep -qiv 'llvmpipe\|lavapipe\|swiftshader'; then
            warn "only software Vulkan devices; install the Vulkan driver for your GPU"
        fi
    fi
else
    warn "vulkaninfo not installed, Vulkan devices not listed ($(aegnux_pkg_hint vulkan-tools))"
fi

echo "Wine runtime libraries"
MISSING_LIBS=$(aegnux_wine_libs_missing | tr '\n' ' ')
if [ -z "$MISSING_LIBS" ]; then
    ok "every library the Wine runner loads at run time is installed"
else
    for s in $MISSING_LIBS; do
        case "$s" in
            libXcomposite.so.1) fail "$s missing: OpenGL child windows stay black, so After Effects' Composition panel shows nothing" ;;
            libX11.so.6|libXext.so.6|libXrender.so.1|libXi.so.6|libXrandr.so.2|libXfixes.so.3) fail "$s missing: Wine's X11 driver loses input, drawing or display handling" ;;
            libxkbcommon.so.0|libxkbregistry.so.0) fail "$s missing: Wine's X11 driver cannot read the keyboard layout" ;;
            libfreetype.so.6) fail "$s missing: Wine cannot draw text" ;;
            libEGL.so.1|libGL.so.1) fail "$s missing: Wine has no OpenGL (the Composition panel and Advanced 3D need it)" ;;
            *) warn "$s missing: a smaller Wine feature is off (cursors, multi-monitor, font lookup, TLS or gamma)" ;;
        esac
    done
    echo "          $(aegnux_pkg_hint $MISSING_LIBS)"
fi

if is_wsl; then
    echo "OpenGL"
    if [ "${AEGNUX_SYSTEM_GL:-0}" = 1 ]; then
        ok "AEGNUX_SYSTEM_GL=1: the distribution's OpenGL is used"
    elif [ -f "$AEGNUX_GL_PREFIX/lib/libEGL.so.1" ]; then
        ok "Mesa 25.2.8 EGL and d3d12 driver: $AEGNUX_GL_PREFIX (first in LD_LIBRARY_PATH for Wine)"
    else
        # The distribution's Mesa version is in the file name of its libgallium.
        DMESA=$(for f in /usr/lib/x86_64-linux-gnu/libgallium-*.so /usr/lib64/libgallium-*.so /usr/lib/libgallium-*.so; do
                    [ -e "$f" ] && basename "$f" | sed -n 's/^libgallium-\([0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\).*\.so$/\1/p'
                done | head -n 1)
        case "${DMESA:-}" in
            25.*) ok "OpenGL: the distribution's Mesa $DMESA (the version tested is 25.2.8); scripts/build_gl.sh would give every distribution the same one" ;;
            "") warn "no private OpenGL stack at $AEGNUX_GL_PREFIX and the distribution's Mesa version is unknown; run scripts/build_gl.sh" ;;
            *) warn "OpenGL: the distribution's Mesa $DMESA is not the tested version (25.2.8): with Mesa 26 After Effects' Composition panel stayed empty. Run scripts/build_gl.sh" ;;
        esac
    fi
    GL=""
    for d in /usr/lib/x86_64-linux-gnu/dri /usr/lib64/dri /usr/lib/dri; do
        if [ -e "$d/d3d12_dri.so" ]; then GL="$d/d3d12_dri.so"; break; fi
    done
    if [ -n "$GL" ]; then ok "the distribution's Mesa D3D12 GL driver: $GL"; elif [ ! -f "$AEGNUX_GL_PREFIX/lib/libEGL.so.1" ]; then warn "Mesa's d3d12_dri.so not found: AE's OpenGL display will use llvmpipe (slow); install your distribution's Mesa DRI drivers or run scripts/build_gl.sh"; fi
    if [ "${AEGNUX_REP_MOVSB:-0}" = 1 ]; then
        warn "AEGNUX_REP_MOVSB=1: glibc's memcpy keeps using rep movsb, which copies at about 45 MB/s into the d3d12 upload buffers; RAM preview plays at about a fifth of real time"
    else
        ok "glibc's memcpy is kept off rep movsb for Wine (GLIBC_TUNABLES, set by aegnux_env in common.sh)"
    fi
fi

echo "Direct3D DLLs in the prefix"
SYS32="$WINEPREFIX/drive_c/windows/system32"
for dll in dxgi.dll d3d11.dll d3d12.dll d3d12core.dll; do
    f="$SYS32/$dll"
    if [ ! -f "$f" ]; then fail "$dll missing (install DXVK and vkd3d-proton into the prefix)"; continue; fi
    if grep -aq "Wine builtin DLL" "$f"; then warn "$dll is Wine's builtin; DXVK / vkd3d-proton expected"; continue; fi
    SUM=$(sha256sum "$f" | cut -c1-64)
    if printf '%s\n' "$TESTED_DLLS" | grep -qx "$dll $SUM"; then
        ok "$dll: tested build"
    else
        warn "$dll: untested build (sha256 ${SUM:0:16}...); tested with DXVK 3.0.1 and vkd3d-proton 3.0.1"
    fi
done

echo "CUDA and the Composition panel"
CUDA_LIB=""
for l in /usr/lib/wsl/lib/libcuda.so.1 $(ldconfig -p 2>/dev/null | sed -n 's/.*libcuda\.so\.1 .*=> //p'); do
    if [ -e "$l" ]; then CUDA_LIB=$l; break; fi
done
if [ "${AEGNUX_DISABLE_CUDA:-0}" = 1 ]; then
    ok "CUDA hidden from AE: nvcuda and nvcuvid are disabled, and launch_ae.sh sets DZN_DEBUG=nocudauuid so dzn does not query CUDA. AE renders in software; Advanced 3D is unavailable"
elif [ -n "$CUDA_LIB" ] && [ -e "$SYS32/nvcuda.dll" ]; then
    ok "CUDA available to AE ($CUDA_LIB)"
    if [ "${AEGNUX_DIRECTX_DISPLAY:-0}" = 1 ]; then
        warn "AEGNUX_DIRECTX_DISPLAY=1: the Composition panel stays empty while CUDA is in use"
    else
        APPLIED=0
        while IFS= read -r dir; do
            if grep -q "^DS\.DisableDirectXDisplay$(printf '\t')true" "$dir/Debug Database.txt" 2>/dev/null; then
                ok "DirectX display disabled for AE ${dir##*/} (needed for the Composition panel)"
                APPLIED=1
            fi
        done < <(aegnux_ae_pref_dirs)
        if [ "$APPLIED" = 0 ]; then warn "display settings not applied yet (launch_ae.sh or scripts/ae_prefs.sh applies them)"; fi
    fi
else
    ok "CUDA not available: AE renders in software and does not use its DirectX display"
fi

echo "Test tools (tests/)"
MISSING=""
have xdotool || MISSING="$MISSING xdotool"
have xwininfo || MISSING="$MISSING x11-utils"
have x86_64-w64-mingw32-gcc || MISSING="$MISSING mingw-gcc"
if [ -n "$MISSING" ]; then warn "missing:$MISSING ($(aegnux_pkg_hint $MISSING))"; else ok "xdotool, xwininfo, mingw-w64 gcc"; fi
if have Xvfb; then
    ok "Xvfb (tests run on a private display)"
else
    NOTE=""
    if [ "$(aegnux_family)" = zypper ] && is_wsl; then NOTE="; under WSL that package conflicts with patterns-wsl-tmpfiles, see docs/known-issues.md"; fi
    warn "Xvfb not installed: AE tests run on your desktop ($(aegnux_pkg_hint xvfb))$NOTE"
fi

if [ "${1:-}" = --build ]; then
    echo "Build tools (build_dzn.sh)"
    MISSING=$(aegnux_build_missing)
    if [ -n "$MISSING" ]; then
        fail "the dzn build is missing:"
        printf '%s\n' "$MISSING" | sed 's/^/          /'
        echo "          $(aegnux_pkg_hint gcc gcc-c++ git pkg-config ninja python3-mako)"
        echo "          $(aegnux_mesa_dev_hint)"
    else
        ok "meson $(meson --version), ninja, cc, pkg-config, git, python3 and the Mesa libraries"
    fi
    if [ -f "$MESA_SRC/meson.build" ]; then ok "Mesa source: $MESA_SRC"; else warn "no Mesa source at $MESA_SRC: set MESA_TARBALL to mesa-25.2.8.tar.xz"; fi
    if ! is_wsl; then warn "dzn only works under WSL; native hosts do not need build_dzn.sh"; fi
fi

echo
echo "$FAILS failure(s), $WARNS warning(s)"
[ "$FAILS" -eq 0 ]