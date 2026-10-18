# aegnux-wine-ae

Patches and helper scripts to run Adobe After Effects 2024 (24.6.2) under Wine.
Under WSL2 the GPU is reached through Mesa's Dozen (dzn) Vulkan driver on top of
Direct3D 12; on a native Linux host the host's own Vulkan driver is used.

Nothing here contains Adobe binaries. You need your own, legally obtained After
Effects installation and a Wine runner (aegnux sets both up).

Tested only on: Windows 11, WSL2, Ubuntu 24.04, NVIDIA RTX 4060 Ti, Wine TkG 11.12,
DXVK 3.0.1, vkd3d-proton 3.0.1, After Effects 24.6.2. The scripts detect other
distributions and native hosts, but those paths are untested.

## Status (2026-10-18)

| Item | Status |
|---|---|
| AE starts and stays up without an exception | Verified (docs/technical-note.md) |
| Crash `vkCreateDevice Exception 0xc0000005` / malloc corruption | Fixed (patch 02) |
| D3D12 device loss during AE start | Fixed (patch 06) |
| Black Direct3D 11 swapchain windows | Fixed (patch 17); `tests/run_dxgi_present_test.sh` |
| Empty Composition panel | Fixed by an AE preference that `launch_ae.sh` applies; `tests/run_ae_viewer_test.sh` |
| GPUSniffer DirectX test | Passes (result 529) |
| Advanced 3D | Listed and kept as the comp renderer, 3D layers show in the panel, but GPU rendering through Direct3D 12 is not happening. See docs/known-issues.md |
| Conformance | None. dzn prints "not a conformant Vulkan implementation" |

## What is in this repository

```
patches/   17 patches (git format-patch) against pristine Mesa 25.2.8
scripts/   build_dzn.sh     build and install dzn (WSL only)
           launch_ae.sh     start AE (applies ae_prefs.sh and clear_crash_state.sh)
           stop_ae.sh       stop AE and its wineserver
           doctor.sh        check the host and the setup, print install hints
           ae_prefs.sh      AE preferences this setup needs (see below)
           common.sh        shared settings, platform detection, config file
           gpu_sniffer_test.sh, dzn_audit.c, gen_cmds.py, apiver_layer/, tools/xcap.c
tests/     run_dxgi_present_test.sh   D3D11 swapchain shows its backbuffer (patch 17)
           run_ae_viewer_test.sh      Composition panel shows a rendered comp
docs/      technical note (findings, evidence) and known issues
```

The patches are one logical change each. They apply in order with `git apply`
to the official Mesa 25.2.8 tarball (sha256
`097842f3e49d996868b38688db87b006f7d4541e93ce86d2f341d8b3e7be7c93`).

## Platforms

| Host | Vulkan | OpenGL | Notes |
|---|---|---|---|
| WSL2 | dzn from this repository (Vulkan on Direct3D 12) | Mesa's D3D12 Gallium driver (`GALLIUM_DRIVER=d3d12`) | Needs a WSLg-capable Windows GPU driver (`/dev/dxg`, `/usr/lib/wsl/lib/libd3d12.so`) |
| Native Linux, any distribution | The host's Vulkan driver (RADV, ANV, NVIDIA, ...) | The host's GL driver | dzn is not built or used. Untested |

`AEGNUX_VULKAN=dzn` or `AEGNUX_VULKAN=system` overrides the automatic choice.

## Check your setup

```sh
scripts/doctor.sh           # host, display, Wine, prefix, AE, Vulkan, GL, DLL versions, CUDA
scripts/doctor.sh --build   # also the tools build_dzn.sh needs
```

`doctor.sh` only reads. For anything missing it prints an install command for the
detected distribution family (apt, dnf, pacman, zypper); the package names are
hints. It also reports whether the DXVK / vkd3d-proton DLLs in the prefix are the
tested builds, so that an update of those components is visible before it causes
trouble.

## Build (WSL2 only)

```sh
export MESA_TARBALL=/path/to/mesa-25.2.8.tar.xz   # or MESA_SRC=<unpacked tree>
scripts/build_dzn.sh
```

`build_dzn.sh` checks for meson, ninja, a C compiler, pkg-config, git and
python3-mako first and prints an install hint if one is missing. It verifies the
tarball checksum, applies `patches/*.patch` once (marker file in the source tree),
configures a release build with `-Dvulkan-drivers=microsoft-experimental`, builds
`libvulkan_dzn.so` and installs it with an ICD manifest under `$DZN_PREFIX`
(default `$AEGNUX_HOME/dzn`). Meson fetches DirectX-Headers from GitHub during
configure; set `https_proxy` if needed.

The build lives in its own prefix, so updates of the distribution's Mesa do not
affect it. The install locations are written to the config file (below), so the
other scripts find the build without extra variables.

## Run

```sh
scripts/launch_ae.sh        # start AE; logs in $AEGNUX_LOG_DIR/ae_<timestamp>/
scripts/launch_ae.sh 150    # stop AE after 150 s (for testing)
scripts/stop_ae.sh
```

Before starting AE, `launch_ae.sh` clears the previous-crash state (so the "Crash
Repair Options" dialog does not block startup), applies `ae_prefs.sh`, and checks
that the dzn ICD (WSL) and `AfterFX.exe` exist.

### AE preferences applied by ae_prefs.sh

Applied to every AE version folder in the prefix and to the installed version (read
from `AMT/application.xml`), so new AE versions and the first start are covered.

| Setting | Why | Opt out |
|---|---|---|
| `DS.DisableDirectXDisplay = true` (Debug Database) | With CUDA available, AE shows Composition panel frames through its DirectX display, which passes images between CUDA and Direct3D 12. Wine's CUDA bridge cannot share resources with vkd3d-proton, so that display never presents and the panel stays empty. | `AEGNUX_DIRECTX_DISPLAY=1` |
| `"Show Welcome Screen" = 00` (Prefs) | The HTML Home screen renders as an empty panel that covers the workspace. | `AEGNUX_HIDE_HOME_SCREEN=0` |

## Configuration

Each setting comes from the environment, otherwise from
`~/.config/aegnux/aegnux.conf` (plain `KEY=value` lines; `AEGNUX_CONFIG` points
elsewhere), otherwise from the defaults in `scripts/common.sh`.

| Variable | Default | Meaning |
|---|---|---|
| `AEGNUX_HOME` | `~/.local/share/aegnux` | aegnux data folder |
| `WINE_BIN_DIR` | `$AEGNUX_HOME/runner/bin` | Wine runner |
| `WINEPREFIX` | `$AEGNUX_HOME/wineprefix` | Wine prefix |
| `AE_DIR` | `$AEGNUX_HOME/AE` | folder with `AfterFX.exe` |
| `DZN_PREFIX` | `$AEGNUX_HOME/dzn` | dzn install (written by build_dzn.sh) |
| `AEGNUX_VULKAN` | `auto` | `dzn`, `system` or `auto` |
| `AEGNUX_DISABLE_CUDA` | `0` | `1` hides CUDA from AE: software rendering, AE then reports Advanced 3D as unsupported |
| `AEGNUX_DIRECTX_DISPLAY` | `0` | `1` keeps AE's DirectX display (empty panel while CUDA is used) |
| `AEGNUX_HIDE_HOME_SCREEN` | `1` | `0` keeps AE's Home screen setting |
| `AEGNUX_EXTRA_OVERRIDES` | empty | extra `WINEDLLOVERRIDES` entries |
| `AEGNUX_WINEDEBUG` | errors only | `WINEDEBUG` for AE |
| `AEGNUX_APIVER_LAYER` | `0` | `1` enables the optional apiVersion layer (unnecessary with patch 04) |

## Tests

```sh
tests/run_dxgi_present_test.sh   # needs mingw-w64 gcc, xdotool, python3
tests/run_ae_viewer_test.sh      # needs xdotool, xwininfo, python3; uses Xvfb if installed
```

`run_ae_viewer_test.sh` starts AE with a temporary startup script that creates a
comp with a red solid and an Invert effect, captures the screen and passes if the
Composition panel shows the cyan result. With Xvfb installed it runs on a private
display, so nothing appears on the desktop and input cannot interfere. It stops any
running AE of the prefix. With `AEGNUX_DIRECTX_DISPLAY=1` (the setup before the
fix) it fails, as expected.

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
- Adobe After Effects, Wine and the GPU drivers are not part of this repository
  and keep their own licenses.

## Known limitations (short list; full list in docs/known-issues.md)

- Advanced 3D does not render on the GPU (Direct3D 12) yet.
- The Composition panel uses AE's non-DirectX display while CUDA is available.
- VK_EXT_transform_feedback is a no-op stub. Stream output does not work.
- inlineUniformBlock and nullDescriptor are advertised because DXVK 3.x requires
  them, but dzn does not implement them.
- Only the configuration listed at the top was tested.