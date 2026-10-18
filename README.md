# NuxFX

Adobe After Effects 2024 on Linux, through Wine. The GPU is reached through Mesa's
Dozen (dzn) Vulkan driver, DXVK and vkd3d-proton; CUDA goes through a bridge in the
Wine prefix.

NuxFX holds the patch series and the scripts for that setup. It contains no Adobe
software and no Wine runner. It was developed under the name `aegnux-wine-ae`.

> **Experimental.** Tested on one configuration: Windows 11, WSL2, Ubuntu 24.04,
> NVIDIA GeForce RTX 4060 Ti, After Effects 24.6.2. Advanced 3D does not work yet.
> See [Status](#status) and [Gaps](#gaps).

## Contents

- [Status](#status)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start (WSL2)](#quick-start-wsl2)
- [Updating](#updating)
- [Configuration](#configuration)
- [Tests](#tests)
- [Repository layout](#repository-layout)
- [Documentation](#documentation)
- [Gaps](#gaps)
- [License](#license)

## Status

| Area | Status | Notes |
|---|---|---|
| AE starts and stays up | Works | No exception at start. See `docs/technical-note.md` |
| Composition panel | Works | `ae_prefs.sh` turns off AE's DirectX display; test: `tests/run_ae_viewer_test.sh` |
| Direct3D 11 swapchain windows | Works | Patch 17; test: `tests/run_dxgi_present_test.sh` |
| Classic 3D renderer | Works | Panel and render queue (TIFF) checked with a test comp |
| Advanced 3D renderer (`ADBE Calder`) | **Does not work** | Frames are solid magenta (255, 0, 255). AE shows no error. See below |
| Cinema 4D renderer (`ADBE Ernst`) | **Does not work** | AE's plugin scan does not recognise `Ernst.aex`; rendering not tested |
| Effects on the GPU | Partly | Only Invert and solids were checked |
| CUDA | Partly | Device queries work (patch 18 fixes `cuDeviceGetLuid`). Direct3D interop is not implemented |
| GPUSniffer DirectX test | Passes | Result 529 |
| Vulkan conformance | Not tested | No CTS run. dzn prints "not a conformant Vulkan implementation" |
| Native Linux hosts | Untested | The scripts detect them, nothing was run there |
| AMD and Intel GPUs | Untested | |

**Advanced 3D.** Selecting Advanced 3D (`ADBE Calder`) gives solid magenta frames in
the panel and in renders. The cause is not found yet. AE's plugin scan does not load
`Calder.aex` under Wine (`No loaders recognized this plugin`). Changing the feature
level, hiding or showing the NVIDIA adapter, the DirectX display or the CUDA setting
did not change that. Note the naming: the match name `ADBE Advanced 3d` is the
classic renderer, Classic 3D. Details are in `docs/known-issues.md`.

## How it works

```mermaid
flowchart LR
    AE["After Effects 2024<br/>AfterFX.exe"] --> WINE["Wine runner<br/>(aegnux, TkG 11.12)"]
    WINE -- "Direct3D 11" --> DXVK["DXVK 3.0.1"]
    WINE -- "Direct3D 12" --> VKD3D["vkd3d-proton 3.0.1"]
    WINE -- "CUDA" --> NVCUDA["nvcuda bridge<br/>(nvidia-libs)"]
    DXVK --> VK["Vulkan"]
    VKD3D --> VK
    VK --> DZN["Mesa dzn<br/>(patches in patches/)"]
    DZN -- "WSL2 /dev/dxg" --> D3D12["Direct3D 12 in WSL"]
    D3D12 --> GPU["NVIDIA GPU"]
    NVCUDA --> LIBCUDA["libcuda in WSL"]
    LIBCUDA --> GPU
```

- **WSL2:** dzn implements Vulkan on top of Direct3D 12. The Direct3D 12 driver is
  reached through `/dev/dxg`. The patches in `patches/` apply to pristine Mesa 25.2.8.
  OpenGL goes through Mesa's D3D12 Gallium driver (`GALLIUM_DRIVER=d3d12`), which the
  scripts set under WSL.
- **Native Linux:** the host's own Vulkan driver (RADV, ANV, NVIDIA, ...) is used and
  dzn is not built. Untested.

## Requirements

- Windows with a GPU driver that supports GPU access in WSL (`/dev/dxg` and
  `/usr/lib/wsl/lib/libd3d12.so`). Tested with an NVIDIA driver.
- WSL2 with Ubuntu 24.04. Tested. The scripts detect other distributions, untested.
- After Effects 2024, version 24.6.2, a copy you are licensed to use, in
  `$AEGNUX_HOME/AE` (or set `AE_DIR`).
- A Wine runner and a prefix. They come from the aegnux setup and are not part of this
  repository. Tested with Wine TkG 11.12 and the DXVK 3.0.1 and vkd3d-proton 3.0.1 DLLs
  in the prefix. `scripts/doctor.sh` reports whether those DLLs match the tested builds
  (by SHA-256).
- To build dzn: meson, ninja, a C compiler, pkg-config, git and python3-mako.
  `scripts/doctor.sh --build` lists what is missing and prints an install hint.
- The Mesa 25.2.8 release tarball, or an unpacked tree. The build checks the tarball's
  SHA-256.
- Network access during the build. Meson downloads DirectX-Headers from GitHub. Set
  `https_proxy` if you need a proxy.

## Quick start (WSL2)

```sh
# 1. Check the host. Read-only.
scripts/doctor.sh --build

# 2. Build and install dzn with the patch series.
export MESA_TARBALL=/path/to/mesa-25.2.8.tar.xz    # or MESA_SRC=/path/to/unpacked/tree
scripts/build_dzn.sh

# 3. Start After Effects. Logs go to $AEGNUX_LOG_DIR/ae_<timestamp>/.
scripts/launch_ae.sh
scripts/stop_ae.sh
```

`launch_ae.sh` clears the previous-crash state, so the Crash Repair dialog does not
block startup. It applies `ae_prefs.sh` before every start, and it checks that the
dzn ICD and `AfterFX.exe` exist. `scripts/launch_ae.sh 150` stops AE after 150 seconds,
which is useful for tests.

### Preferences set by `ae_prefs.sh`

The script applies these to every AE preferences folder in the prefix and to the folder
of the installed version, read from `AMT/application.xml`.

| Setting | Why | Opt out |
|---|---|---|
| `DS.DisableDirectXDisplay = true` (Debug Database) | With CUDA available, AE shows Composition panel frames through its DirectX display. That display passes images between CUDA and Direct3D 12. The Wine CUDA bridge cannot share those resources, so the panel stayed empty. | `AEGNUX_DIRECTX_DISPLAY=1` |
| `"Show Welcome Screen" = 00` (Prefs) | The HTML Home screen renders as an empty panel that covers the workspace. | `AEGNUX_HIDE_HOME_SCREEN=0` |

## Updating

Update this repository, then run `scripts/build_dzn.sh` again. The build records the
patches it has applied in `.aegnux-patches-applied`, in the Mesa tree. It applies only
the patches that are missing, so new patches go onto an existing tree. A tree built
before the record existed is detected from the patches that reverse cleanly.

The build lives in its own prefix, so the distribution's Mesa is not changed. The
install locations go into the config file, so the other scripts find the build without
extra variables. `doctor.sh` also reports whether the DXVK and vkd3d-proton DLLs in the
prefix are the tested builds, so an update of those is visible before it causes trouble.

## Configuration

Each setting comes from the environment. If it is not set there, it comes from
`~/.config/aegnux/aegnux.conf` (plain `KEY=value` lines; `AEGNUX_CONFIG` points
elsewhere). If it is not there either, the default in `scripts/common.sh` is used.

| Variable | Default | Meaning |
|---|---|---|
| `AEGNUX_HOME` | `~/.local/share/aegnux` | Data folder |
| `WINE_BIN_DIR` | `$AEGNUX_HOME/runner/bin` | Wine runner |
| `WINEPREFIX` | `$AEGNUX_HOME/wineprefix` | Wine prefix |
| `AE_DIR` | `$AEGNUX_HOME/AE` | Folder that contains `AfterFX.exe` |
| `DZN_PREFIX` | `$AEGNUX_HOME/dzn` | dzn install, written by `build_dzn.sh` |
| `AEGNUX_VULKAN` | `auto` | `dzn`, `system` or `auto` |
| `AEGNUX_DISABLE_CUDA` | `0` | `1` hides CUDA from AE. AE then renders in software and reports Advanced 3D as unsupported |
| `AEGNUX_DIRECTX_DISPLAY` | `0` | `1` keeps AE's DirectX display (the panel stays empty while CUDA is used) |
| `AEGNUX_HIDE_HOME_SCREEN` | `1` | `0` keeps AE's Home screen setting |
| `AEGNUX_EXTRA_OVERRIDES` | empty | Extra `WINEDLLOVERRIDES` entries |
| `AEGNUX_WINEDEBUG` | errors only | `WINEDEBUG` for AE |
| `AEGNUX_APIVER_LAYER` | `0` | `1` enables the optional apiVersion layer. Not needed with patch 04 |

## Tests

```sh
tests/run_dxgi_present_test.sh   # D3D11 swapchain shows its backbuffer (patch 17)
tests/run_ae_viewer_test.sh      # Composition panel shows a rendered comp
scripts/gpu_sniffer_test.sh      # dzn entrypoint audit, then AE's GPUSniffer DirectX test
```

- `run_dxgi_present_test.sh` needs `x86_64-w64-mingw32-gcc`, gcc with X11 headers,
  xdotool and python3.
- `run_ae_viewer_test.sh` needs xdotool, xwininfo, python3 and gcc with X11 headers. It
  starts AE with a temporary startup script. That script creates a comp with a red solid
  and an Invert effect, and the test passes if the Composition panel shows cyan. With
  Xvfb installed the test runs on a private display, so nothing appears on your desktop.
  It stops any AE of the prefix that is running. With `AEGNUX_DIRECTX_DISPLAY=1` it
  fails, as expected.

## Repository layout

```
patches/   18 patches (git format-patch) against pristine Mesa 25.2.8
scripts/   build_dzn.sh          build and install dzn (WSL2)
           launch_ae.sh          start AE (applies ae_prefs.sh and clear_crash_state.sh)
           stop_ae.sh            stop AE and its wineserver
           doctor.sh             read-only check of host, prefix, AE and tools
           ae_prefs.sh           AE preferences this setup needs
           clear_crash_state.sh  clears AE's previous-crash state
           common.sh             shared settings, platform detection, config file
           gpu_sniffer_test.sh   entrypoint audit, then GPUSniffer
           dzn_audit.c, gen_cmds.py   entrypoint audit of dzn
           apiver_layer/        optional Vulkan layer (apiVersion), off by default
           tools/xcap.c         X11 screen capture for the tests
tests/     run_dxgi_present_test.sh, run_ae_viewer_test.sh, dxgi_present_test.c
docs/      technical-note.md    findings and evidence, section by section
           known-issues.md      fixed and open issues, stubs, limitations
```

## Documentation

- [`docs/technical-note.md`](docs/technical-note.md): how each problem was narrowed
  down, with the evidence.
- [`docs/known-issues.md`](docs/known-issues.md): fixed issues, open issues, stubs and
  limitations.

## Gaps

What is missing, broken or not decided yet.

**Not working**

- Advanced 3D (`ADBE Calder`) renders solid magenta frames. The cause is not found.
- The Cinema 4D renderer (`ADBE Ernst`) is not recognised by AE's plugin scan under
  Wine. Rendering was not tested.

**Not tested**

- Native Linux hosts, distributions other than Ubuntu 24.04, AMD and Intel GPUs, and
  AE versions other than 24.6.2.
- Effects other than Invert and solids.
- Large projects and long render sessions.

**Missing or incomplete in dzn**

- `VK_EXT_transform_feedback` is a no-op stub (patch 09). Stream output is dropped.
- `inlineUniformBlock` and `nullDescriptor` are advertised (patch 15), because DXVK 3.0.1
  needs them, but they are not implemented. Open decision: implement them or stop
  advertising them.
- Sparse resources are not supported. vkd3d-proton therefore stops at Direct3D 12
  feature level 11_1.
- The robustness features are advertised without a dedicated test.
- No Vulkan CTS run. dzn is not a conformant Vulkan implementation.

**Missing in the CUDA bridge**

- Direct3D interop: `cuGraphicsD3D11RegisterResource` returns
  `CUDA_ERROR_NOT_SUPPORTED`. Features that share images between CUDA and Direct3D are
  affected.

**Packaging and setup**

- The Wine runner, the aegnux prefix, nvidia-libs (nvcuda), and the DXVK and vkd3d-proton
  DLLs are not included. `doctor.sh` checks their versions, but the repository does not
  download or pin them.
- There are no instructions here for creating the runner and the prefix, and no
  installer. After Effects is placed by hand.
- No CI. The tests need a desktop-like X session and xdotool.
- The code and the configuration still use the `aegnux` name: the `AEGNUX_*`
  variables, `~/.local/share/aegnux`, `aegnux.conf`. The rename to NuxFX covers only
  the repository and this README.

**Decisions open**

- **License:** none chosen. Until one is added, the code carries no reuse permission.
  Choose one before making the repository public.
- **Visibility:** the repository was created private.

## License

No license has been chosen yet, so there is no permission to reuse this code.

The patches modify Mesa, which is mostly MIT-licensed. The modified Mesa files keep
Mesa's license terms.

Adobe After Effects, Wine, DXVK, vkd3d-proton, nvidia-libs and the GPU drivers are not
part of this repository and keep their own licenses. Adobe and After Effects are
trademarks of Adobe. This project is not affiliated with Adobe.
