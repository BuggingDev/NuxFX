# aegnux-wine-ae

Experimental patches and helper scripts to run Adobe After Effects 2024 (24.6.2)
under Wine inside WSL2 (Ubuntu 24.04), using Mesa's Dozen (dzn) Vulkan driver
on top of Direct3D 12, so that the GPU path and Advanced 3D can be evaluated.

Nothing here contains Adobe binaries. You need your own, legally obtained After
Effects 2024 installation and Wine runner (aegnux sets both up).

## Status (2026-10-18)

| Item | Status |
|---|---|
| AE starts and stays up for 150 s without an exception | Verified (see docs/technical-note.md) |
| Crash `vkCreateDevice Exception 0xc0000005` / malloc corruption | Fixed; root cause and evidence in docs |
| D3D12 device loss (DXGI_ERROR_DEVICE_HUNG) during AE start | Fixed (VK_KHR_maintenance6 bind calls were silent no-ops) |
| GPUSniffer DirectX test | Passes (result 529) |
| Advanced 3D | Plugin loads, renderer can be selected in Composition Settings, a 3D layer can be created. Rendered output was NOT verified. See docs/known-issues.md |
| Conformance | None. dzn prints "not a conformant Vulkan implementation" |

## What is in this repository

```
patches/   16 patches (git format-patch) against pristine Mesa 25.2.8
docs/      technical note (findings, evidence) and known issues
scripts/   build, launch, crash-state, GPU sniffer test, dzn audit, apiVersion layer
           scripts/tools/xcap.c captures one X11 window (for UI checks)
```

The patches are one logical change each. They apply in order with `git apply`
to the official Mesa 25.2.8 tarball (sha256
`097842f3e49d996868b38688db87b006f7d4541e93ce86d2f341d8b3e7be7c93`). Only
these files change: `src/util/ralloc.c`, `src/microsoft/vulkan/dzn_*.c`,
`src/microsoft/vulkan/dzn_private.h`, `src/microsoft/spirv_to_dxil/dxil_spirv_nir.c`.

## Prerequisites

- Windows 11 with WSL2 and a WSLg-capable NVIDIA driver (the D3D12 interface is
  provided by `/usr/lib/wsl/lib/libd3d12.so` in the WSL distribution).
- Ubuntu 24.04 in WSL2, with build tools: `build-essential meson ninja-build
  python3-mako python3-yaml bison flex libvulkan-dev libx11-dev libxcb-dri3-dev
  libxcb-present-dev libxshmfence-dev libwayland-dev libdrm-dev libzstd-dev
  pkg-config` (package names may differ between releases).
- Mesa 25.2.8 source. Either a tree at `$MESA_SRC` or the release tarball at
  `$MESA_TARBALL`.
- A Wine runner suitable for AE. The debugging was done with Wine TkG 11.12
  (the aegnux runner). Set `WINE_BIN_DIR` to its `bin` directory.
- An After Effects 2024 (24.6.2) installation you own, at `$AE_DIR`
  (containing `AfterFX.exe`, `GPUSniffer.exe` and `Support Files`).
- An aegnux prefix at `$WINEPREFIX` (default `$AEGNUX_HOME/wineprefix`).

## Build

```sh
export AEGNUX_HOME="$HOME/.local/share/aegnux"
export MESA_SRC="$HOME/src/mesa-25.2.8"        # or set MESA_TARBALL
export WINE_BIN_DIR="$AEGNUX_HOME/runner/bin"
export AE_DIR="$AEGNUX_HOME/AE"
scripts/build_dzn.sh                            # applies patches, builds, installs
```

Meson fetches DirectX-Headers 1.0 from GitHub during configure. If you need a proxy,
set `https_proxy` before running the script.

`build_dzn.sh` applies `patches/*.patch` to `$MESA_SRC` once (it leaves a marker
file), configures a release build with `-Dvulkan-drivers=microsoft-experimental`,
builds `libvulkan_dzn.so` and installs it with an ICD manifest under
`$DZN_PREFIX` (default `$AEGNUX_HOME/dzn`). It also builds the apiVersion layer
(see below) under `$AEGNUX_LAYER_DIR`.

## Run

```sh
scripts/gpu_sniffer_test.sh                     # DirectX check with GPUSniffer.exe
scripts/launch_ae.sh 150                        # run AE for 150 s, logs in $AEGNUX_LOG_DIR
scripts/stop_ae.sh                              # stop AE and its wineserver
```

`launch_ae.sh` clears the previous-crash state first (`clear_crash_state.sh`),
so that AE does not stop at the "Crash Repair Options" dialog. Each run writes
`out.log`, `err.log` and `rc` into a new directory under `$AEGNUX_LOG_DIR`.
Success criteria used during development: no `0xc0000005` line, no `malloc()`
line, at least four `Creating device` lines (DXVK), and AE still running when
the timeout ends (rc 124).

## Optional: heap validation for dzn debugging

Build dzn with `-DRALLOC_DEBUG_VALIDATE=1` (or edit the default in
`src/util/ralloc.c`) to get double-free and use-after-free reports with call
stacks on stderr. It is off by default and slows allocation down.

## Licenses

- Mesa is MIT licensed. These patches are modifications of Mesa and carry the
  same license terms for the modified files.
- aegnux is GPL-3.0. The scripts in this repository are written to be used with
  aegnux. No license file has been chosen for this repository yet; choose one
  before publishing it.
- Adobe After Effects, Wine and the NVIDIA driver are not part of this
  repository and keep their own licenses.

## Known limitations (short list; full list in docs/known-issues.md)

- VK_EXT_transform_feedback is a no-op stub. Stream output does not work.
- inlineUniformBlock and nullDescriptor are advertised because DXVK 3.x requires
  them, but dzn does not implement them.
- The apiVersion workaround (patch 04 and the layer) changes what an application
  sees about the API version.
- Advanced 3D: rendering output was not verified.
- Not tested on other GPUs, other Windows builds or other AE versions.