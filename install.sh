#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# One-command installer: asks every question first (After Effects folder, plugin and
# extension folders, install folder), shows the plan, then installs without further input:
# system packages, Wine runner, dzn (Direct3D 12 route), Wine prefix, DXVK, vkd3d-proton, the CUDA
# bridge, After Effects and your plugins. Safe to run again: finished parts are skipped.
#
#   ./install.sh [options]
#     -y, --yes            take every default (needs an After Effects folder it can find,
#                          or --ae-dir)
#     --ae-dir DIR         After Effects "Support Files" folder (the one with AfterFX.exe)
#     --plugins DIR        folder of .aex plugins to import (repeatable)
#     --extensions DIR     folder of CEP extensions to import (repeatable)
#     --home DIR           install folder (default ~/.local/share/aegnux)
#     --no-packages        do not install system packages
#     --no-cuda            do not install the CUDA bridge
#     --no-dzn            do not build dzn (default on native Linux)
#     --force              redo parts that look finished
#     --dry-run            show the plan and the commands, change nothing
#     -h, --help           this text
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

YES=0; DRY=0; FORCE=0; PACKAGES=1; CUDA=1; DZN=auto
OPT_HOME=""; OPT_AE=""; PLUGIN_DIRS=(); EXT_DIRS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) YES=1 ;;
        --ae-dir) OPT_AE=${2:-}; shift ;;
        --plugins) PLUGIN_DIRS+=("${2:-}"); shift ;;
        --extensions) EXT_DIRS+=("${2:-}"); shift ;;
        --home) OPT_HOME=${2:-}; shift ;;
        --no-packages) PACKAGES=0 ;;
        --no-cuda) CUDA=0 ;;
        --no-dzn) DZN=0 ;;
        --force) FORCE=1 ;;
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '5,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$OPT_HOME" ] && export AEGNUX_HOME="$OPT_HOME"

. "$HERE/scripts/common.sh"

# Pinned downloads. The hashes are those of the releases everything was tested with.
WINE_VER=11.12
WINE_URL="https://github.com/Kron4ek/Wine-Builds/releases/download/$WINE_VER/wine-$WINE_VER-staging-tkg-amd64-wow64.tar.xz"
WINE_SHA=5cf2bcee41ae2c926c8fade6297d5c0c3e9cbe1d1f0a77d69197d739af805e59
DXVK_URL="https://github.com/doitsujin/dxvk/releases/download/v3.0.1/dxvk-3.0.1.tar.gz"
DXVK_SHA=bebb6284db590535b7b005c102ebf6850c98842cff0fded9aacb74babae14c49
VKD3D_URL="https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v3.0.1/vkd3d-proton-3.0.1.tar.zst"
VKD3D_SHA=3cf2315522af5e43605ef6d3c41dad91387040bf97199934f3f7ab76caaa2f0c
NVLIBS_URL="https://github.com/SveSop/nvidia-libs/releases/download/v1.0.2/nvidia-libs-v1.0.2.tar.xz"
NVLIBS_SHA=01e8bb6368d088e22d8e8f1d02497214e8db436476021725ef0c0707b7cb1738
# winetricks is a single shell script. The distributions' packages differ (Debian keeps it in
# contrib, which is not enabled by default), so the pinned upstream script is used.
WT_URL="https://raw.githubusercontent.com/Winetricks/winetricks/20250102/src/winetricks"
WT_SHA=53194dead910f8a5eb1deacaa4773d4e48f5873633d18ab1ecd6fdb0cb92243b
MESA_URL="https://archive.mesa3d.org/mesa-25.2.8.tar.xz"
MESA_SHA=097842f3e49d996868b38688db87b006f7d4541e93ce86d2f341d8b3e7be7c93

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
say()  { printf '%s\n' "$*"; }
head1(){ printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
good() { printf '  %sok%s    %s\n' "$G" "$N" "$*"; }
note() { printf '  %s!%s     %s\n' "$Y" "$N" "$*"; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
have() { command -v "$1" > /dev/null 2>&1; }

# ask_yn "question" default(y|n)
ask_yn() {
    local a
    if [ "$YES" = 1 ]; then [ "$2" = y ]; return; fi
    read -r -p "$1 [$( [ "$2" = y ] && echo Y/n || echo y/N )] " a || die "no terminal for questions (use --yes)"
    case "${a:-$2}" in [yYeE]*) return 0 ;; *) return 1 ;; esac
}

# browse DEFAULT: folder dialog when zenity can show one, else nothing
browse() {
    if have zenity && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        zenity --file-selection --directory --title="NuxFX: choose a folder" --filename="${1:-$HOME}/" 2> /dev/null
    fi
}

# ask_dir "question" default: prints the chosen folder (empty = none). "b" opens a dialog.
ask_dir() {
    local a
    if [ "$YES" = 1 ]; then printf '%s\n' "$2"; return; fi
    read -r -p "$1 [${2:-none}] (b = browse) " a < /dev/tty || die "no terminal for questions (use --yes)"
    case "$a" in
        "") printf '%s\n' "$2" ;;
        b|B) browse "$2" ;;
        *) printf '%s\n' "${a/#\~/$HOME}" ;;
    esac
}

ae_version_of() {
    sed -n 's/.*<Data key="ProductVersion">\([0-9][0-9.]*\).*/\1/p' "$1/AMT/application.xml" 2> /dev/null | head -n 1
}

# Drives of a Windows installation that are mounted here (a dual-boot disk, a shared drive):
# /mnt/<x>, /media/<user>/<label> and /run/media/<user>/<label> that have a "Program Files" folder.
windows_drives() {
    local d
    for d in /mnt/* /media/*/* /run/media/*/*; do
        if [ -d "$d/Program Files" ]; then printf '%s\n' "$d"; fi
    done
}

# Normalises a path the user typed: accepts the "Support Files" folder or its parent.
fix_ae_path() {
    local p=$1
    if [ ! -f "$p/AfterFX.exe" ] && [ -f "$p/Support Files/AfterFX.exe" ]; then p="$p/Support Files"; fi
    printf '%s\n' "$p"
}

head1 "NuxFX installer"
if is_d3d12_host; then
    ENVNAME="Direct3D 12 route"
    [ "$DZN" = auto ] && DZN=1
else
    ENVNAME="host-driver route"
    [ "$DZN" = auto ] && DZN=0
fi
say "  Host:    $( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}" ) ($ENVNAME)"
say "  Install: $AEGNUX_HOME"
[ "$ENVNAME" = "host-driver route" ] && note "the host-driver route has not been run on bare hardware yet; the host's Vulkan driver is used and dzn is skipped"
if [ "$(id -u)" = 0 ]; then
    note "running as root: Wine would create a root-owned prefix; run this as a normal user"
    case " $(. /etc/os-release 2> /dev/null; echo "${ID:-} ${ID_LIKE:-}") " in
        *" debian "*|*" ubuntu "*) say "  create one with:  adduser nux && usermod -aG sudo nux   (needs the sudo package)" ;;
        *) say "  create one with:  useradd -m -G wheel nux && passwd nux   (needs the sudo package and a wheel rule in sudoers)" ;;
    esac
    say "  then start a shell as that user (su - nux) and run the installer again."
    die "do not run the installer as root"
fi

# ---------- questions ----------

head1 "1. After Effects"
AE_SRC=""
if [ -n "$OPT_AE" ]; then
    AE_SRC=$(fix_ae_path "$OPT_AE")
elif [ -f "$AE_DIR/AfterFX.exe" ] && [ "$FORCE" = 0 ]; then
    AE_SRC=$AE_DIR
    good "already installed in $AE_DIR (kept; use --force to copy again)"
else
    CANDS=()
    mapfile -t DRIVES < <(windows_drives)
    for drive in "${DRIVES[@]}"; do
        for d in "$drive/Program Files/Adobe"/Adobe\ After\ Effects*/Support\ Files; do
            [ -f "$d/AfterFX.exe" ] && CANDS+=("$d")
        done
    done
    if [ ${#CANDS[@]} -gt 0 ]; then
        say "  Found on this PC:"
        i=1
        for d in "${CANDS[@]}"; do
            v=$(ae_version_of "$d")
            say "    $i) $d  (version ${v:-unknown})"
            i=$((i + 1))
        done
        say "    p) type or browse for another folder"
        if [ "$YES" = 1 ]; then sel=1; else read -r -p "  Choose [1] " sel < /dev/tty || die "no terminal (use --yes or --ae-dir)"; fi
        sel=${sel:-1}
        case "$sel" in
            [0-9]*) AE_SRC=${CANDS[$((sel - 1))]:-} ;;
        esac
    fi
    while [ -z "$AE_SRC" ] || [ ! -f "$AE_SRC/AfterFX.exe" ]; do
        [ "$YES" = 1 ] && die "no After Effects found; pass --ae-dir DIR"
        say "  Choose the After Effects \"Support Files\" folder (it contains AfterFX.exe)."
        say "  On Windows: C:\\Program Files\\Adobe\\Adobe After Effects 2024\\Support Files"
        AE_SRC=$(fix_ae_path "$(ask_dir "  Folder" "")")
    done
fi
[ -f "$AE_SRC/AfterFX.exe" ] || die "AfterFX.exe not found in: $AE_SRC"
AE_V=$(ae_version_of "$AE_SRC")
good "After Effects folder: $AE_SRC (version ${AE_V:-unknown})"
case "$AE_V" in 24.6*) ;; *) note "only 24.6.x was tested; other versions may not start" ;; esac

head1 "2. Plugins and extensions (optional)"
say "  Where they go inside the Wine prefix:"
PLUG_DEST="$WINEPREFIX/drive_c/Program Files/Adobe/Common/Plug-ins/7.0/MediaCore"
CEP_DEST="$WINEPREFIX/drive_c/Program Files (x86)/Common Files/Adobe/CEP/extensions"
CEP_USER_DEST=$(dirname "$(aegnux_ae_roaming)")/CEP/extensions
say "    plugins (.aex)   $PLUG_DEST"
say "    extensions (CEP) $CEP_DEST"
say "    your extensions  $CEP_USER_DEST"
mapfile -t DRIVES < <(windows_drives)
if [ ${#PLUGIN_DIRS[@]} -eq 0 ]; then
    for drive in "${DRIVES[@]}"; do
        d="$drive/Program Files/Adobe/Common/Plug-ins/7.0/MediaCore"
        if [ -d "$d" ] && ask_yn "  Import the third-party plugins of your Windows install ($d)? Some need Windows libraries that are not copied" n; then PLUGIN_DIRS+=("$d"); fi
    done
fi
if [ ${#EXT_DIRS[@]} -eq 0 ]; then
    for drive in "${DRIVES[@]}"; do
        d="$drive/Program Files (x86)/Common Files/Adobe/CEP/extensions"
        if [ -d "$d" ] && ask_yn "  Import the CEP extensions of your Windows install ($d)?" n; then EXT_DIRS+=("$d"); fi
    done
fi
if [ "$YES" = 0 ]; then
    while :; do
        d=$(ask_dir "  Another plugin folder (.aex), empty to continue" "")
        [ -n "$d" ] || break
        if [ -d "$d" ]; then PLUGIN_DIRS+=("$d"); else note "not a folder: $d"; fi
    done
    while :; do
        d=$(ask_dir "  Another extension folder (CEP), empty to continue" "")
        [ -n "$d" ] || break
        if [ -d "$d" ]; then EXT_DIRS+=("$d"); else note "not a folder: $d"; fi
    done
fi
for d in "${PLUGIN_DIRS[@]}"; do [ -d "$d" ] || die "plugin folder not found: $d"; done
for d in "${EXT_DIRS[@]}"; do [ -d "$d" ] || die "extension folder not found: $d"; done

# ---------- GPU facts ----------

HAVE_CUDA=0
for l in "$AEGNUX_D3D12_LIBDIR/libcuda.so.1" $(ldconfig -p 2> /dev/null | sed -n 's/.*libcuda\.so\.1 .*=> //p'); do
    [ -e "$l" ] && HAVE_CUDA=1 && break
done
[ "$CUDA" = 1 ] && [ "$HAVE_CUDA" = 0 ] && CUDA=0
[ "$HAVE_CUDA" = 0 ] && note "no libcuda found: the CUDA bridge is skipped and AE renders in software (Advanced 3D unavailable)"

# A Wine program with a large working set needs many memory mappings, and some distributions
# still ship the kernel default of 65530 (a likely cause of crashes when memory use is high).
MAPS=$(cat /proc/sys/vm/max_map_count 2> /dev/null || echo 0)
RAISE_MAPS=0
if [ "$PACKAGES" = 1 ] && [ "$MAPS" -lt 1048576 ] 2> /dev/null; then RAISE_MAPS=1; fi

# ---------- plan ----------

head1 "Plan"
say "  Install folder    $AEGNUX_HOME"
say "  After Effects     $AE_SRC"
say "  System packages   $([ "$PACKAGES" = 1 ] && echo yes || echo skipped)"
say "  Memory mappings   $([ "$RAISE_MAPS" = 1 ] && echo "vm.max_map_count $MAPS, raised to 1048576 (sudo, /etc/sysctl.d/99-nuxfx.conf)" || echo "vm.max_map_count $MAPS, left alone")"
say "  Wine runner       $WINE_VER (Wine TkG staging, checked by SHA-256)"
say "  dzn (Mesa)        $([ "$DZN" = 1 ] && echo "build from source, takes a while" || echo skipped)"
say "  OpenGL (Mesa)     $([ "$DZN" = 1 ] && echo "build from source (EGL and the d3d12 driver, same Mesa version)" || echo skipped)"
say "  DXVK / vkd3d      3.0.1 / 3.0.1"
say "  CUDA bridge       $([ "$CUDA" = 1 ] && echo "nvidia-libs 1.0.2" || echo skipped)"
say "  Plugins           ${#PLUGIN_DIRS[@]} folder(s)"
say "  Extensions        ${#EXT_DIRS[@]} folder(s)"
[ "$DRY" = 1 ] && { say; say "dry run: nothing changed"; exit 0; }
ask_yn "Start the installation?" y || { say "cancelled"; exit 1; }

# ---------- install ----------

mkdir -p "$AEGNUX_HOME/downloads" "$AEGNUX_LOG_DIR"
LOG="$AEGNUX_LOG_DIR/install_$(date +%Y%m%d_%H%M%S).log"
say "  log: $LOG"
STEP=0; TOTAL=12
step() { STEP=$((STEP + 1)); head1 "[$STEP/$TOTAL] $*"; }
# run DESCRIPTION CMD...: output goes to the log; on failure the tail is shown
run() {
    local desc=$1; shift
    printf '  %s ... ' "$desc"
    echo "### $desc: $*" >> "$LOG"
    # stdin is closed so that no tool can wait for an answer, and the log is capped (a tool
    # that loops on a prompt once wrote gigabytes); a capped tool dies of SIGPIPE.
    "$@" < /dev/null 2>&1 | head -c 200000000 >> "$LOG"
    if [ "${PIPESTATUS[0]}" = 0 ]; then printf '%sdone%s\n' "$G" "$N"; else
        printf '%sFAILED%s\n' "$R" "$N"; tail -n 25 "$LOG" >&2
        die "step failed: $desc (full log: $LOG)"
    fi
}

# soft DESCRIPTION CMD...: like run, but a failure only prints a note
soft() {
    local desc=$1; shift
    printf '  %s ... ' "$desc"
    echo "### $desc: $*" >> "$LOG"
    if "$@" < /dev/null >> "$LOG" 2>&1; then printf '%sdone%s\n' "$G" "$N"; else printf '%sfailed%s (the installation goes on)\n' "$Y" "$N"; fi
}

# fetch URL FILE SHA256: resumes, verifies
fetch() {
    local url=$1 file=$2 sha=$3
    if [ -f "$file" ] && [ "$(sha256sum "$file" | cut -c1-64)" = "$sha" ]; then good "$(basename "$file") already downloaded"; return 0; fi
    printf '  downloading %s\n' "$(basename "$file")"
    curl -fL --retry 3 -C - -# -o "$file" "$url" || true
    [ -f "$file" ] || die "download failed: $url"
    [ "$(sha256sum "$file" | cut -c1-64)" = "$sha" ] || { rm -f "$file"; die "SHA-256 mismatch for $(basename "$file"); removed it"; }
    good "$(basename "$file") verified"
}

DL="$AEGNUX_HOME/downloads"
# The wineserver writes the registry files when it exits (a few seconds after its last
# client). The vkd3d-proton installer looks for system.reg, so wait for that.
settle() { run "waiting for the wineserver" "$WINE_BIN_DIR/wineserver" -w; }

# The package managers ask "Proceed?" and the installer closes stdin, so the commands get
# their non-interactive flags here (the question was asked above).
noninteractive() {
    sed -e 's/^sudo apt install/sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y/' \
        -e 's/^sudo dnf install/sudo dnf install -y/' \
        -e 's/^sudo pacman -S --needed/sudo pacman -S --needed --noconfirm/' \
        -e 's/^sudo zypper install/sudo zypper --non-interactive install/'
}

step "System packages"
if [ "$PACKAGES" = 1 ]; then
    # which: vkd3d-proton's setup script finds Wine with it (openSUSE's image has none)
    BASE=(git curl tar xz zstd cabextract pkg-config awk procps which)
    if [ "$DZN" = 1 ]; then
        BASE+=(gcc gcc-c++ ninja python3-mako)
        # Debian and Ubuntu releases ship a meson that can be too old (24.04: 1.3); the other
        # distributions' meson is current. The old case is handled after the packages.
        if have apt-get; then BASE+=(pipx python3-venv); else BASE+=(meson); fi
    fi
    # The Vulkan loader is needed by Wine on every host; on the Direct3D 12 route the OpenGL
    # driver (Mesa's d3d12 Gallium driver) comes from the distribution's Mesa package.
    BASE+=(vulkan-loader)
    is_d3d12_host && BASE+=(mesa-dri)
    # python3 plays the silent stream that keeps the sound server of the Direct3D 12 route awake while
    # After Effects runs (scripts/sound_keepalive.sh; pacat does it as well), otherwise RAM preview breaks.
    BASE+=(python3)
    # Libraries the Wine runner opens at run time. It does not complain when one is missing:
    # without libXcomposite After Effects' Composition panel stays black.
    WINE_LIBS=$(aegnux_wine_libs_missing | tr '\n' ' ')
    # shellcheck disable=SC2206
    BASE+=($WINE_LIBS)
    CMD=$(aegnux_pkg_hint "${BASE[@]}")
    MISSING_ANY=0
    for t in git curl tar xz zstd cabextract awk pgrep which; do have "$t" || MISSING_ANY=1; done
    [ -n "$WINE_LIBS" ] && MISSING_ANY=1
    ldconfig -p 2> /dev/null | grep -q 'libvulkan\.so\.1' || MISSING_ANY=1
    if is_d3d12_host; then
        ls /usr/lib/x86_64-linux-gnu/dri/d3d12_dri.so /usr/lib64/dri/d3d12_dri.so /usr/lib/dri/d3d12_dri.so > /dev/null 2>&1 || MISSING_ANY=1
    fi
    have python3 || MISSING_ANY=1
    if [ "$DZN" = 1 ] && [ -n "$(aegnux_build_missing)" ]; then MISSING_ANY=1; fi
    if [ "$MISSING_ANY" = 1 ]; then
        say "  needs: $CMD"
        [ "$DZN" = 1 ] && say "         $(aegnux_mesa_dev_hint)"
        if ask_yn "  Run these with sudo?" y; then
            # A fresh system has no package lists, or lists that are incomplete (a fresh Ubuntu image found no
            # candidate for cabextract, ninja-build and pipx), so apt refreshes them first.
            have apt-get && soft "updating the package lists" sudo apt-get update
            run "installing base packages" env DEBIAN_FRONTEND=noninteractive bash -c "$(printf '%s\n' "$CMD" | noninteractive)"
            [ "$DZN" = 1 ] && run "installing Mesa build libraries" env DEBIAN_FRONTEND=noninteractive bash -c "$(aegnux_mesa_dev_hint | noninteractive)"
        else
            note "skipped; the steps below may fail"
        fi
    else
        good "everything needed is installed"
    fi
    STILL=$(aegnux_wine_libs_missing | tr '\n' ' ')
    [ -z "$STILL" ] || note "still missing: $STILL (scripts/doctor.sh explains what each one does)"
else
    note "skipped (--no-packages)"
fi
if [ "$RAISE_MAPS" = 1 ]; then
    if sudo sh -c "mkdir -p /etc/sysctl.d && echo 'vm.max_map_count=1048576' > /etc/sysctl.d/99-nuxfx.conf && sysctl -w vm.max_map_count=1048576" >> "$LOG" 2>&1; then
        good "vm.max_map_count raised from $MAPS to 1048576 (/etc/sysctl.d/99-nuxfx.conf)"
    else
        note "could not raise vm.max_map_count (now $MAPS); later: echo 'vm.max_map_count=1048576' | sudo tee /etc/sysctl.d/99-nuxfx.conf && sudo sysctl --system"
    fi
fi
if [ "$DZN" = 1 ] && [ -n "$(aegnux_build_missing | grep '^meson')" ]; then
    # pipx first; some distributions ship a pipx with a missing dependency, so a private
    # virtual environment is the fallback.
    export PATH="$HOME/.local/bin:$PATH"
    if have pipx && pipx install meson < /dev/null >> "$LOG" 2>&1; then
        good "meson $(meson --version) installed with pipx"
    else
        MV="$AEGNUX_HOME/meson-venv"
        run "installing meson in $MV" bash -c "python3 -m venv '$MV' && '$MV/bin/pip' install meson"
        export PATH="$MV/bin:$PATH"
    fi
    case "$(meson --version 2> /dev/null)" in
        "") die "meson could not be installed; install meson 1.4 or newer and run again" ;;
    esac
fi

step "Wine runner"
if [ -x "$WINE_BIN_DIR/wine" ] && [ "$FORCE" = 0 ]; then
    good "found: $("$WINE_BIN_DIR/wine" --version 2> /dev/null)"
else
    fetch "$WINE_URL" "$DL/wine-$WINE_VER.tar.xz" "$WINE_SHA"
    mkdir -p "$AEGNUX_HOME/runner"
    run "unpacking the runner" tar -xJf "$DL/wine-$WINE_VER.tar.xz" -C "$AEGNUX_HOME/runner" --strip-components=1
    [ -x "$WINE_BIN_DIR/wine" ] || die "the runner has no bin/wine in $WINE_BIN_DIR"
fi
# vkd3d-proton's installer and winetricks ask which Wine to use when "wine" and "wine64"
# resolve to different folders (a distribution's own wine64 is enough to trigger it).
[ -e "$WINE_BIN_DIR/wine64" ] || ln -s wine "$WINE_BIN_DIR/wine64"

# True when the dzn build already contains every patch of this checkout (or when that cannot
# be told because the source tree is elsewhere).
dzn_uptodate() {
    local applied="${MESA_SRC:-$AEGNUX_HOME/src/mesa-25.2.8}/.aegnux-patches-applied" p
    [ -f "$applied" ] || return 0
    for p in "$HERE"/patches/*.patch; do grep -qF "$(basename "$p")" "$applied" || return 1; done
}

step "Vulkan driver (dzn)"
if [ "$DZN" = 1 ]; then
    if [ -f "$(aegnux_dzn_icd)" ] && [ "$FORCE" = 0 ] && dzn_uptodate; then
        good "found: $(aegnux_dzn_icd)"
    else
        [ -f "$(aegnux_dzn_icd)" ] && note "the dzn build lacks newer patches; rebuilding it"
        fetch "$MESA_URL" "$DL/mesa-25.2.8.tar.xz" "$MESA_SHA"
        export MESA_SRC="$AEGNUX_HOME/src/mesa-25.2.8" MESA_BUILD="$AEGNUX_HOME/src/mesa-25.2.8/build" MESA_TARBALL="$DL/mesa-25.2.8.tar.xz"
        say "  building Mesa (several minutes; progress is in the log)"
        run "building dzn" "$HERE/scripts/build_dzn.sh"
    fi
else
    good "not needed here"
fi

step "OpenGL driver (Mesa EGL and d3d12)"
if [ "$DZN" = 1 ]; then
    # Wine's OpenGL (After Effects' Composition panel) runs on Mesa 25.2.8 from its own prefix,
    # so it does not depend on the Mesa of the distribution (26.x left the panel empty).
    if [ -f "$AEGNUX_GL_PREFIX/lib/libEGL.so.1" ] && [ "$FORCE" = 0 ]; then
        good "found: $AEGNUX_GL_PREFIX"
    else
        fetch "$MESA_URL" "$DL/mesa-25.2.8.tar.xz" "$MESA_SHA"
        export MESA_SRC="$AEGNUX_HOME/src/mesa-25.2.8" MESA_BUILD="$AEGNUX_HOME/src/mesa-25.2.8/build" MESA_TARBALL="$DL/mesa-25.2.8.tar.xz"
        say "  building Mesa's OpenGL driver (a few minutes; progress is in the log)"
        run "building the OpenGL driver" "$HERE/scripts/build_gl.sh"
    fi
else
    good "not needed here"
fi

# keep the locations for the other scripts
mkdir -p "$(dirname "$AEGNUX_CONFIG")"
touch "$AEGNUX_CONFIG"
sed -i '/^AEGNUX_DISABLE_CUDA=/d' "$AEGNUX_CONFIG"
[ "$CUDA" = 1 ] || echo "AEGNUX_DISABLE_CUDA=1" >> "$AEGNUX_CONFIG"
for kv in "AEGNUX_HOME=$AEGNUX_HOME" "AE_DIR=$AE_DIR" "WINE_BIN_DIR=$WINE_BIN_DIR" "WINEPREFIX=$WINEPREFIX"; do
    sed -i "/^${kv%%=*}=/d" "$AEGNUX_CONFIG"
    printf '%s\n' "$kv" >> "$AEGNUX_CONFIG"
done

aegnux_env
SYS32="$WINEPREFIX/drive_c/windows/system32"
SYS64="$WINEPREFIX/drive_c/windows/syswow64"

step "Wine prefix"
if [ -f "$WINEPREFIX/system.reg" ] && [ "$FORCE" = 0 ]; then
    good "found: $WINEPREFIX"
else
    mkdir -p "$WINEPREFIX"
    run "creating the prefix" wineboot -i
    run "setting Windows 10" wine reg add 'HKCU\Software\Wine' /v Version /d win10 /f
    settle
fi

step "Visual C++ runtime and d3dcompiler"
# Wine ships builtin copies of these DLLs, so the files prove nothing; winetricks keeps a log.
if grep -qx vcrun2022 "$WINEPREFIX/winetricks.log" 2> /dev/null \
   && grep -qx d3dcompiler_47 "$WINEPREFIX/winetricks.log" 2> /dev/null && [ "$FORCE" = 0 ]; then
    good "found"
else
    fetch "$WT_URL" "$DL/winetricks-20250102" "$WT_SHA"
    mkdir -p "$AEGNUX_HOME/bin"
    install -m 755 "$DL/winetricks-20250102" "$AEGNUX_HOME/bin/winetricks"
    run "winetricks vcrun2022 d3dcompiler_47 (slow)" "$AEGNUX_HOME/bin/winetricks" -q vcrun2022 d3dcompiler_47
    settle
fi

step "DXVK and vkd3d-proton"
if [ -f "$SYS32/dxgi.dll" ] && ! grep -aq "Wine builtin DLL" "$SYS32/dxgi.dll" \
   && [ -f "$SYS32/d3d12.dll" ] && ! grep -aq "Wine builtin DLL" "$SYS32/d3d12.dll" && [ "$FORCE" = 0 ]; then
    good "found"
else
    fetch "$DXVK_URL" "$DL/dxvk-3.0.1.tar.gz" "$DXVK_SHA"
    fetch "$VKD3D_URL" "$DL/vkd3d-proton-3.0.1.tar.zst" "$VKD3D_SHA"
    run "unpacking DXVK" tar -xzf "$DL/dxvk-3.0.1.tar.gz" -C "$DL"
    for dll in d3d9 d3d10core d3d11 dxgi; do
        cp "$DL/dxvk-3.0.1/x64/$dll.dll" "$SYS32/"
        cp "$DL/dxvk-3.0.1/x32/$dll.dll" "$SYS64/"
        run "override $dll" wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$dll" /d "native,builtin" /f
    done
    rm -rf "$DL/vkd3d-proton-3.0.1"
    run "unpacking vkd3d-proton" tar --zstd -xf "$DL/vkd3d-proton-3.0.1.tar.zst" -C "$DL"
    settle
    run "installing vkd3d-proton" bash -c "cd '$DL/vkd3d-proton-3.0.1' && ./setup_vkd3d_proton.sh install"
    settle
fi

step "CUDA bridge"
if [ "$CUDA" = 1 ]; then
    if [ -f "$SYS32/nvcuda.dll" ] && [ "$FORCE" = 0 ]; then
        good "found"
    else
        fetch "$NVLIBS_URL" "$DL/nvidia-libs-v1.0.2.tar.xz" "$NVLIBS_SHA"
        mkdir -p "$WINEPREFIX/nvidia-libs"
        run "unpacking nvidia-libs" tar -xJf "$DL/nvidia-libs-v1.0.2.tar.xz" -C "$WINEPREFIX/nvidia-libs"
        run "installing nvidia-libs" "$WINEPREFIX/nvidia-libs/nvidia-libs-v1.0.2/setup_nvlibs.sh" install
        settle
    fi
else
    good "skipped"
fi

step "After Effects files"
if [ "$AE_SRC" = "$AE_DIR" ] || { [ -f "$AE_DIR/AfterFX.exe" ] && [ "$FORCE" = 0 ]; }; then
    good "already in $AE_DIR"
else
    SZ=$(du -sh "$AE_SRC" 2> /dev/null | cut -f1)
    mkdir -p "$AE_DIR"
    # Modes are not copied: files from a Windows drive arrive read-only (r-xr-xr-x), and
    # After Effects writes into its own folders.
    if have rsync; then
        run "copying ${SZ:-?} to $AE_DIR" rsync -rlt "$AE_SRC/" "$AE_DIR/"
    else
        run "copying ${SZ:-?} to $AE_DIR" cp -r --no-preserve=mode,ownership "$AE_SRC/." "$AE_DIR/"
    fi
fi
# Also repairs an earlier copy whose files are read-only.
chmod -R u+rwX,go+rX "$AE_DIR" 2> /dev/null || true
if [ -f "$AE_DIR/CEPHtmlEngine/d3dcompiler_47.dll" ]; then
    run "Adobe's d3dcompiler_47 for Advanced 3D" cp "$AE_DIR/CEPHtmlEngine/d3dcompiler_47.dll" "$SYS32/d3dcompiler_47.dll"
else
    note "CEPHtmlEngine/d3dcompiler_47.dll not found: Advanced 3D needs it"
fi

step "Plugins and extensions"
copy_in() { # SRC DEST
    mkdir -p "$2"
    cp -rn "$1/." "$2/"
}
if [ ${#PLUGIN_DIRS[@]} -eq 0 ] && [ ${#EXT_DIRS[@]} -eq 0 ]; then
    good "none chosen (put .aex files in: $PLUG_DEST)"
    mkdir -p "$PLUG_DEST" "$CEP_DEST" "$CEP_USER_DEST"
fi
for d in "${PLUGIN_DIRS[@]}"; do run "plugins from $d" copy_in "$d" "$PLUG_DEST"; done
for d in "${EXT_DIRS[@]}"; do run "extensions from $d" copy_in "$d" "$CEP_DEST"; done
chmod -R u+rwX,go+rX "$PLUG_DEST" "$CEP_DEST" "$CEP_USER_DEST" 2> /dev/null || true

step "Settings and menu entry"
run "AE preferences" "$HERE/scripts/ae_prefs.sh"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$APPS"
cat > "$APPS/nuxfx-after-effects.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=After Effects (NuxFX)
Comment=Adobe After Effects under Wine
Exec=$HERE/scripts/launch_ae.sh
Terminal=false
Categories=Graphics;AudioVideo;
EOF
good "menu entry: $APPS/nuxfx-after-effects.desktop"

step "Check"
"$HERE/scripts/doctor.sh" || note "doctor.sh reported failures; read them above"

head1 "Done"
say "  Start:  $HERE/scripts/launch_ae.sh   (or the \"After Effects (NuxFX)\" menu entry)"
say "  Stop:   $HERE/scripts/stop_ae.sh"
say "  Plugins and extensions can be added later to:"
say "    $PLUG_DEST"
say "    $CEP_DEST"
say "  Log: $LOG"
