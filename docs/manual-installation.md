# Manual installation

`install.sh` performs these steps in this order. Use this page to repeat or understand a step,
or to set NuxFX up on a distribution the installer does not know. `$AEGNUX_HOME` is
`~/.local/share/aegnux` unless you changed it.

Two GPU routes exist (see "How it works" in the [README](../README.md)). Steps marked
*Direct3D 12 hosts* apply only where the GPU is reachable through Direct3D 12 (the route the
fresh-image tests used); on a Linux machine with a native GPU driver skip them and set
`AEGNUX_VULKAN=system`.

The Windows launcher `install.cmd` runs `install.sh` for you from Windows (it needs a Linux
distribution installed in WSL2).

## 1. GPU drivers

- **Native driver.** Install your GPU's Vulkan driver (RADV, ANV or NVIDIA) and, for CUDA and
  Advanced 3D, the current NVIDIA driver, which provides `libcuda.so.1`. Check with
  `vulkaninfo --summary` and `nvidia-smi`.
- **Direct3D 12 hosts.** Install the current NVIDIA driver for Windows, then check inside Linux:

  ```sh
  ls /dev/dxg /usr/lib/wsl/lib/libd3d12.so /usr/lib/wsl/lib/libcuda.so.1
  nvidia-smi
  ```

## 2. System packages

Install the packages for your distribution. They cover the builds (step 3), the Wine helper tools
(steps 4 to 7) and the tests.

**Ubuntu, Debian, Linux Mint, Pop!_OS**

```sh
sudo apt update
sudo apt install build-essential git pkg-config ninja-build python3-mako pipx python3-venv \
    curl xz-utils zstd cabextract gawk procps debianutils gcc-mingw-w64-x86-64 libx11-dev \
    x11-utils xdotool xvfb libvulkan1 libgl1-mesa-dri
pipx ensurepath
pipx install meson
```

Open a new shell after `pipx ensurepath`. Ubuntu 24.04 ships meson 1.3, which is too old for
Mesa 25.2.8 (it needs meson 1.4 or newer), so meson comes from pipx. Check with
`meson --version`. Debian has no `winetricks` package in main; step 5 uses the upstream script.

**Fedora**

```sh
sudo dnf install gcc gcc-c++ git pkgconf-pkg-config ninja-build python3-mako meson \
    curl xz zstd cabextract gawk procps-ng which mingw64-gcc libX11-devel xdotool xwininfo \
    xorg-x11-server-Xvfb vulkan-loader mesa-dri-drivers
```

**Arch Linux, Manjaro, EndeavourOS**

```sh
sudo pacman -S --needed base-devel git pkgconf ninja meson python-mako curl xz zstd cabextract \
    gawk procps-ng which mingw-w64-gcc libx11 xdotool xorg-xwininfo xorg-server-xvfb \
    vulkan-icd-loader mesa
```

**openSUSE**

```sh
sudo zypper install -t pattern devel_basis
sudo zypper install git pkgconf ninja meson python313-Mako curl xz zstd cabextract gawk procps \
    which mingw64-cross-gcc libX11-devel xdotool xwininfo libvulkan1 Mesa-dri
```

Use the `python3xx-Mako` that matches `python3 --version`. The `xorg-x11-server-Xvfb` package
conflicts with `patterns-wsl-tmpfiles` on openSUSE's WSL image (see
[known-issues.md](known-issues.md)); only the tests need Xvfb.

Check `meson --version` (1.4 or newer) on every distribution.

### Libraries that Wine opens at run time

Wine loads these with `dlopen`, so a package manager does not pull them in for a runner that is
not a distribution package, and Wine does not complain when one is missing: it switches the
feature off. A missing `libXcomposite` leaves After Effects' Composition panel black although
the frames render. `install.sh` installs them, `scripts/doctor.sh` lists the missing ones with the
install command for your distribution, and `tests/run_gl_window_test.sh` checks the effect.

```sh
# Ubuntu, Debian
sudo apt install libx11-6 libxext6 libxi6 libxrandr2 libxrender1 libxfixes3 libxcursor1 \
    libxcomposite1 libxinerama1 libxxf86vm1 libxkbcommon0 libxkbregistry0 libfreetype6 \
    libfontconfig1 libgnutls30 libegl1 libgl1
# Fedora
sudo dnf install libX11 libXext libXi libXrandr libXrender libXfixes libXcursor libXcomposite \
    libXinerama libXxf86vm libxkbcommon freetype fontconfig gnutls libglvnd-egl libglvnd-glx
# Arch Linux
sudo pacman -S --needed libx11 libxext libxi libxrandr libxrender libxfixes libxcursor \
    libxcomposite libxinerama libxxf86vm libxkbcommon freetype2 fontconfig gnutls libglvnd
# openSUSE
sudo zypper install libX11-6 libXext6 libXi6 libXrandr2 libXrender1 libXfixes3 libXcursor1 \
    libXcomposite1 libXinerama1 libXxf86vm1 libxkbcommon0 libxkbregistry0 libfreetype6 \
    libfontconfig1 libgnutls30 libEGL1 libGL1
```

### Libraries for the Mesa builds (Direct3D 12 hosts)

Mesa 25.2.8 needs more development packages than the lists above.

```sh
# Ubuntu, Debian
sudo apt install bison flex glslang-tools python3-yaml python3-packaging libdrm-dev \
    libexpat1-dev zlib1g-dev libelf-dev libzstd-dev libwayland-dev wayland-protocols \
    libx11-xcb-dev libxcb1-dev libxcb-dri3-dev libxcb-present-dev libxcb-randr0-dev \
    libxcb-shm0-dev libxcb-sync-dev libxcb-xfixes0-dev libxcb-keysyms1-dev libxrandr-dev \
    libxshmfence-dev spirv-tools
# Fedora
sudo dnf install bison flex glslang python3-pyyaml python3-packaging libdrm-devel expat-devel \
    zlib-devel libzstd-devel elfutils-libelf-devel wayland-devel wayland-protocols-devel \
    libxcb-devel libX11-devel libXrandr-devel libxshmfence-devel xcb-util-keysyms-devel \
    spirv-tools-devel
# Arch Linux
sudo pacman -S --needed bison flex glslang python-yaml python-packaging libdrm expat zlib zstd \
    libelf wayland wayland-protocols libx11 libxcb libxrandr libxshmfence xcb-util-keysyms \
    spirv-tools
```

openSUSE: `scripts/doctor.sh --build` prints the command (it installs by `pkgconfig(...)`
capability). On any distribution `scripts/doctor.sh --build` and `build_dzn.sh` list what is
still missing, including a meson older than 1.4.

### Memory mappings

A Wine program with a large working set needs many memory mappings, and some distributions still
ship the kernel default `vm.max_map_count` of 65530 (a likely cause of crashes when memory use is
high). The installer raises it to 1048576 when it is lower; by hand:

```sh
cat /proc/sys/vm/max_map_count     # 1048576 or more is fine
echo 'vm.max_map_count=1048576' | sudo tee /etc/sysctl.d/99-nuxfx.conf && sudo sysctl --system
```

## 3. Mesa: dzn and OpenGL (Direct3D 12 hosts)

```sh
cd ~
curl -LO https://archive.mesa3d.org/mesa-25.2.8.tar.xz
git clone https://github.com/chunsal/NuxFX.git
cd NuxFX
MESA_TARBALL="$HOME/mesa-25.2.8.tar.xz" scripts/build_dzn.sh
scripts/build_gl.sh
```

`build_dzn.sh` checks the tarball's SHA-256, applies the patches, builds `libvulkan_dzn.so` and
installs it under `$DZN_PREFIX` (default `$AEGNUX_HOME/dzn`). It writes the install locations to
`~/.config/aegnux/aegnux.conf`. Meson downloads DirectX-Headers from GitHub during configure; set
`https_proxy` if you need a proxy.

`build_gl.sh` builds Mesa's EGL library and its Direct3D 12 OpenGL driver from the same source
tree and installs them under `$AEGNUX_GL_PREFIX` (default `$AEGNUX_HOME/mesa-gl`). `aegnux_env`
puts that folder first in `LD_LIBRARY_PATH`, so Wine's OpenGL does not depend on the
distribution's Mesa. `AEGNUX_SYSTEM_GL=1` uses the distribution's OpenGL instead.

On these hosts `aegnux_env` also sets `GLIBC_TUNABLES=glibc.cpu.x86_rep_movsb_threshold=0x40000000`.
Without it glibc's `memcpy` copies with `rep movsb` from 4 KB up, which ran at about 45 MB/s on
the shared-memory buffers that Mesa's d3d12 driver fills with the viewer's frames, and RAM preview
played at a fifth of real time. `AEGNUX_REP_MOVSB=1` keeps glibc's default. If you start After
Effects without `aegnux_env`, export the variable yourself.

## 4. Wine runner

The runner is **Wine TkG (staging) 11.12**, a prebuilt wow64 build by Kron4ek:

```sh
mkdir -p ~/.local/share/aegnux/runner && cd ~/.local/share/aegnux
curl -LO https://github.com/Kron4ek/Wine-Builds/releases/download/11.12/wine-11.12-staging-tkg-amd64-wow64.tar.xz
echo "5cf2bcee41ae2c926c8fade6297d5c0c3e9cbe1d1f0a77d69197d739af805e59  wine-11.12-staging-tkg-amd64-wow64.tar.xz" | sha256sum -c -
tar -xJf wine-11.12-staging-tkg-amd64-wow64.tar.xz -C runner --strip-components=1
ln -s wine runner/bin/wine64
```

`$AEGNUX_HOME/runner/bin` must contain `wine` and `wineserver`; set `WINE_BIN_DIR` if you put the
runner elsewhere. (`wine64` next to `wine` keeps the vkd3d-proton and winetricks scripts from
asking which one to use.) NTsync is not used when `/dev/ntsync` does not exist; `doctor.sh`
reports it.

## 5. Wine prefix

```sh
cd ~/NuxFX
. scripts/common.sh && aegnux_env     # runner on PATH, prefix location, After Effects' overrides
wineboot -i                           # create the prefix
wine reg add 'HKCU\Software\Wine' /v Version /d win10 /f
# winetricks: your distribution's package, or the upstream script (the installer uses release 20250102)
winetricks -q vcrun2022 d3dcompiler_47
# winetricks installs the 2013 d3dcompiler_47 (6.3.9600). Advanced 3D needs Adobe's newer one,
# which is part of the After Effects folder (step 8):
cp "$AE_DIR/CEPHtmlEngine/d3dcompiler_47.dll" "$WINEPREFIX/drive_c/windows/system32/d3dcompiler_47.dll"
```

`aegnux_env` puts the runner on `PATH` and sets `WINEPREFIX` to `$AEGNUX_HOME/wineprefix`
(default `~/.local/share/aegnux/wineprefix`). Keep that shell open for steps 6 and 7.

## 6. DXVK and vkd3d-proton

Direct3D 11 is translated by DXVK 3.0.1, Direct3D 12 by vkd3d-proton 3.0.1. Download the release
archives:

- DXVK 3.0.1: <https://github.com/doitsujin/dxvk/releases/tag/v3.0.1> (`dxvk-3.0.1.tar.gz`)
- vkd3d-proton 3.0.1: <https://github.com/HansKristian-Work/vkd3d-proton/releases/tag/v3.0.1>
  (`vkd3d-proton-3.0.1.tar.zst`)

DXVK has no install script in its 3.0.1 archive, so copy the DLLs and set the overrides:

```sh
cd ~
tar -xzf dxvk-3.0.1.tar.gz
cp dxvk-3.0.1/x64/{d3d9,d3d10core,d3d11,dxgi}.dll "$WINEPREFIX/drive_c/windows/system32/"
cp dxvk-3.0.1/x32/{d3d9,d3d10core,d3d11,dxgi}.dll "$WINEPREFIX/drive_c/windows/syswow64/"
for dll in d3d9 d3d10core d3d11 dxgi; do
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$dll" /d "native,builtin" /f
done
```

vkd3d-proton ships an install script, which copies its DLLs and sets the overrides (it needs
`which`):

```sh
tar --zstd -xf vkd3d-proton-3.0.1.tar.zst
cd vkd3d-proton-3.0.1
./setup_vkd3d_proton.sh install
cd ~
```

## 7. CUDA bridge

With an NVIDIA GPU. After Effects reaches CUDA through the `nvcuda.dll` of
[nvidia-libs](https://github.com/SveSop/nvidia-libs). Download the release
(`nvidia-libs-v1.0.2.tar.xz`, <https://github.com/SveSop/nvidia-libs/releases/tag/v1.0.2>):

```sh
mkdir -p "$WINEPREFIX/nvidia-libs"
tar -xJf ~/nvidia-libs-v1.0.2.tar.xz -C "$WINEPREFIX/nvidia-libs"
"$WINEPREFIX/nvidia-libs/nvidia-libs-v1.0.2/setup_nvlibs.sh" install
```

The installer links the DLLs from that folder into the prefix, so keep the folder.

## 8. After Effects

Copy the contents of the `Support Files` folder of your After Effects 2024 (24.6.2) installation
to `$AEGNUX_HOME/AE`. The folder must contain `AfterFX.exe`, `AMT/` and `Required/`. Use a copy
you are licensed to use. On Windows the folder is
`C:\Program Files\Adobe\Adobe After Effects 2024\Support Files`.

```sh
mkdir -p "$HOME/.local/share/aegnux/AE"
cp -r "/path/to/Support Files/." "$HOME/.local/share/aegnux/AE/"
```

## 9. Check and start

```sh
cd ~/NuxFX
scripts/doctor.sh          # read-only: reports missing parts and the DLL versions
scripts/launch_ae.sh       # start After Effects; logs go to $AEGNUX_LOG_DIR/ae_<timestamp>/
scripts/stop_ae.sh
```

`doctor.sh` ends with the number of failures and warnings. An "untested build" warning means a
DLL differs from the versions in steps 6 and 7.

`launch_ae.sh` clears the previous-crash state, so the Crash Repair dialog does not block
startup. It applies `ae_prefs.sh` before every start, and it checks that the dzn ICD and
`AfterFX.exe` exist. `scripts/launch_ae.sh 150` stops After Effects after 150 seconds.
