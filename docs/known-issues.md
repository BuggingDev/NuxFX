# Known issues and limitations

Status date: 2026-10-24. Patch numbers refer to `patches/`.

## Stubs and partial implementations

- **VK_EXT_transform_feedback is a stub (patch 09).** The entrypoints exist and do
  nothing. Stream output is dropped, not emulated, so any effect that depends on
  transform feedback renders incorrectly. The extension is advertised only so that
  vkd3d-proton and DXVK accept the device.
- **inlineUniformBlock and nullDescriptor are advertised (patch 15) but not
  implemented.** dzn has no handling for VkWriteDescriptorSetInlineUniformBlock or
  for VK_NULL_HANDLE descriptors. DXVK 3.0.1 refuses to create an adapter without
  these bits, so they stay on. An application that really uses either feature gets
  wrong results.
- **VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE is ignored (patch 11).** The static
  strides from the pipeline are used instead.
- **Robustness bits (patch 15)** robustImageAccess, robustBufferAccess2,
  robustImageAccess2 and EXT_robustness2 are advertised without a dedicated test.
  D3D12's default out-of-range behaviour is assumed to match.
- **VkFormatProperties3 (patch 14)** copies only the three legacy masks. Other 1.3
  fields are not reported separately.
- **Sparse resources** are not supported; the sparse memory requirement queries
  return zero entries.
- **Dynamic vertex strides, sample locations and other dynamic state** beyond what
  dzn already handled are not covered by tests.

## Workarounds (labelled in the code and commit messages)

- **apiVersion raised to 1.3 (patch 04).** An application that asks for an older
  apiVersion gets the device entrypoints gated at 1.3 by the loader. dzn raises the
  instance's app apiVersion and prints one line to stderr. The aegnux layer in
  `scripts/apiver_layer/` does the same from outside the driver. It is optional
  (`AEGNUX_APIVER_LAYER=1`): with the previous default layer path it was never
  loaded and AE still worked, so patch 04 alone is enough.
- **KHR_external_memory_win32 and KHR_external_semaphore_win32** are turned off in
  `_WIN32` builds (patch 15). This is not exercised on Linux.

## Advanced 3D

- The renderer match names are misleading: `ADBE Advanced 3d` is Classic 3D
  (`Required/Advanced3D.aex`, the old name of the classic renderer) and `ADBE Calder`
  is the Advanced 3D renderer added in AE 24 (`Required/Calder.aex`). Earlier notes in
  this repository took `ADBE Advanced 3d` for Advanced 3D, so those tests ran
  Classic 3D.
- Classic 3D renders correctly, in the panel and in the render queue.
- Advanced 3D: renders since patch 19, see "Advanced 3D (`ADBE Calder`): fixed, needs three things".

## Stability and correctness

- Tests were AE runs of about 150 s, the GPUSniffer DirectX test, a native compute
  repro and a device creation loop with a forced meta failure. No Vulkan CTS run was
  done. dzn prints "not a conformant Vulkan implementation" at startup.
- A GPU hang or device loss can still occur from other shaders. AE does not recover
  from device loss, so it stops.
- The heap validation mode (patch 01) is slow and keeps freed blocks allocated.
  It is for debugging only.
- The dzn_audit tool reports NULL entries and stub groups. A single unimplemented
  command that resolves to the stub is not detected.
- The audit list (gen_cmds.py) puts vkCmdWriteBufferMarker2AMD and
  vkGetQueueCheckpointData2NV under VK_KHR_synchronization2. Those two come from AMD
  and NV extensions that dzn does not advertise, so they show as NULL and are
  expected.
- Development logs mention `dxgi: SetBackgroundColor: Not implemented` and Wine
  `fixme` lines. They were not investigated. The `nvcuda` LUID errors are fixed by
  patch 18 (see "Fixed: cuDeviceGetLuid in the CUDA bridge").

## Not included

- Adobe binaries, DLLs and logs. You need your own After Effects 2024 installation.
- The Wine runner and the aegnux prefix. Use aegnux or your own runner.
- The debugging instrumentation used to find the bugs (removed before the patches
  were produced).

## Fixed: empty Composition panel on the first start (Debug Database)

- Symptom: on a fresh install (no AE preferences folder yet) `tests/run_ae_viewer_test.sh`
  failed on the first run and passed on the second, on the same prefix. The panel was
  empty (the panel background, no frame) with the CUDA bridge installed.
- Cause: `ae_prefs.sh` created a `Debug Database.txt` that held only the
  `DS.DisableDirectXDisplay` line. AE treats a file without an `AEDebugDatabaseVersion`
  line as out of date and writes its own defaults at start, so the flag was lost for that
  start (the file AE wrote said `DS.DisableDirectXDisplay false`). The second run patched
  the now versioned file and the flag held.
- Fix: a newly created file starts with `AEDebugDatabaseVersion 2`, as AE's own file does.
  A first run on a removed preferences folder now gives the same 256194 cyan pixels as a
  later run.

## Fixed: empty Composition panel with Mesa 26 (own OpenGL stack)

- Symptom: on Arch Linux (Mesa 26.2.5) the Composition panel stayed empty (the panel
  background, `Frame Render Time: 0ms`) although the OpenGL child window test passed and
  the Debug Database and libXcomposite were right. Ubuntu 24.04 (Mesa 25.2.8) was fine.
- Measured on the same Arch prefix and the same AE start: with the distribution's Mesa
  26.2.5 the viewer test found 0 cyan pixels; with Mesa 25.2.8 (taken from Ubuntu, or built
  from the dzn source tree) it found 78522. AE's `+wgl` call sequences were the same up to
  the point where the Mesa 26 run stopped issuing OpenGL work (the process was idle, every
  thread waiting in the wineserver, so it was not a hang inside Mesa). The pixel format
  AE picks is the same configuration (24 bit depth, 8 bit stencil). What inside Mesa 26's
  d3d12 driver is different was not found.
- Not the cause: threaded OpenGL (`MESA_GLTHREAD=false`, `GALLIUM_THREAD=0`), the Mesa
  shader cache, AE's preferences, the number of EGL devices.
- Fix: `scripts/build_gl.sh` builds Mesa 25.2.8's EGL library and d3d12 driver (the same
  tarball as dzn, about 120 MB of build files, 27 MB installed) into `$AEGNUX_GL_PREFIX`,
  `install.sh` runs it, and `aegnux_env` puts the folder first in `LD_LIBRARY_PATH` for
  Wine. That gives every distribution the Mesa that was tested. `AEGNUX_SYSTEM_GL=1` keeps
  the distribution's own OpenGL.

## Fixed: System Compatibility Report dialog (a second GPU)

- Symptom: Adobe's System Compatibility Report ("Unsupported Video Driver" for `D3D12
  (NVIDIA GeForce RTX 4060 Ti)`, and a CUDA 11.8 warning) opened on every start and waited
  for a click on "Continue with known issues". Acknowledging it did not keep it away on the
  next start. It appeared on Arch Linux, where the user could open `/dev/dri/card0`.
- Cause: Wine makes a GPU of every EGL device. Mesa lists WSLg's `vgem` render node as a
  second device, and when the user can open `card0` it starts that device (software
  fallback `kms_swrast`). Wine then reported a second adapter, `D3D12 (NVIDIA GeForce RTX
  4060 Ti)` with a generic driver version (35.0.10.1000), next to the real one, and AE's
  NVIDIA rules matched it. (Wine source: `init_egl_devices` in `dlls/win32u/opengl.c`.)
- Fix: `aegnux_env` sets `MESA_LOADER_DRIVER_OVERRIDE=d3d12` under WSL. Mesa cannot build
  a screen for `vgem` with that name, so the device is skipped (one EGL device and one GPU
  again), and the display's own EGL path does not change. `tests/run_ae_viewer_test.sh` and
  `tests/run_ae_advanced3d_test.sh` also click the dialog if it ever shows.

## Fixed: black Composition panel on Debian, Fedora and Arch (libXcomposite)

- Symptom: `tests/run_ae_viewer_test.sh` found no cyan pixels. With AE's OpenGL display the
  Composition panel was a black rectangle on Debian 13, Fedora 44 and Arch Linux, while the
  frames rendered correctly (`saveFrameToPng` gave the same image as on Ubuntu 24.04). The
  panel was fine on Ubuntu 24.04. With AE's software display (`GF.DisableAcceleratedDisplay`)
  the panel was correct everywhere, but AE then reported Advanced 3D as unsupported, so that
  was not a fix.
- Cause: Wine opens `libXcomposite.so.1` with `dlopen`. When the library is missing, Wine
  switches XComposite off without any message. An OpenGL child window (AE draws the panel
  into one) is then rendered into an X window that Wine cannot redirect, and the copy to
  the parent window is black. Ubuntu 24.04 has the library installed, the other test
  distributions did not (Wine's package depends on it, a tarball runner does not).
- How it was found: a 100-line Windows program (`tests/gl_window_test.c`: a window with an
  OpenGL child window, cleared to cyan) showed the same black panel on Arch, with correct
  `glReadPixels` values, so the fault was not in AE, in CUDA, in dzn or in Mesa's drivers.
  These changed nothing: Mesa 25.2.8 from Ubuntu instead of Mesa 26.2.5, Ubuntu's Xvfb,
  Xvfb without MIT-SHM, hiding `/dev/dri`, llvmpipe. Installing `libxcomposite` fixed it
  (0 to 220032 cyan pixels, identical to Ubuntu), removing it brought the black panel back.
  Wine's source (`dlls/winex11.drv/init.c`, `client_surface_update_offscreen`) shows the
  dependency: offscreen client windows are redirected with `XCompositeRedirectWindow` and
  copied with `XCopyArea`.
- Fix: `install.sh` installs the libraries the runner opens at run time
  (`AEGNUX_WINE_SONAMES` in `scripts/common.sh`, with the package name for apt and pacman;
  dnf and zypper install by library name), `scripts/doctor.sh` fails when one is missing
  and says what it is needed for, and `tests/run_gl_window_test.sh` checks that an OpenGL
  child window reaches the screen (no After Effects needed).
- The earlier notes here (Mesa versions, `AEGNUX_GPU_DISPLAY`, hiding EGL, the software
  display) were wrong about the cause and are gone.

## Fixed: descriptor bind points and push descriptors (patch 20)

- Symptom: with the CUDA bridge installed, the Composition panel showed a small black
  rectangle instead of the comp (`tests/run_ae_viewer_test.sh`: no cyan pixels) on a fresh
  Ubuntu 24.04. Without the bridge (AE renders in software) the panel was correct, which
  made the bridge look like the cause.
- Cause (from the patch and `tests/run_push_descriptor_test.sh`): dzn picked one bind
  point (compute or graphics) in `vkCmdBindDescriptorSets2KHR` and
  `vkCmdPushDescriptorSet2KHR`, pushed template descriptors into the graphics bind point
  only, and the non-2 `vkCmdPushDescriptorSetKHR` that vkd3d-proton calls resolved to the
  loader's no-op stub, so descriptors were silently dropped. Which of these calls the
  panel depends on was not isolated; the effect was measured with and without the patch.
- Fix: patch 20 updates every bind point that `stageFlags` selects, stores the template's
  bind point, accepts push-descriptor update templates and adds the non-2 KHR wrappers
  (the core 1.4 names stay hidden while dzn reports 1.3). It also returns early when push
  constants arrive before a pipeline bind, passes the plane aspect through
  `GetDeviceImageMemoryRequirements` and stops advertising
  `vulkanMemoryModelAvailabilityVisibilityChains`.
- `build_dzn.sh` writes `api_version` 1.3.318 into the ICD manifest, and
  `tests/run_push_descriptor_test.sh` checks that a compute shader sees a pushed buffer.
- Checked on Ubuntu 24.04 under WSL2 with the OpenGL display on: the viewer test goes from
  0 to 256194 cyan pixels when only this patch is added to the dzn build. The
  `run_push_descriptor_test.sh` check passes with the patch on Ubuntu 24.04, Debian 13,
  Fedora 44 and Arch Linux.

## Fixed: VIEWPORT_WITH_COUNT and SCISSOR_WITH_COUNT (patch 17)

- dzn recognised only the non-count viewport and scissor dynamic states. A pipeline
  that listed VK_DYNAMIC_STATE_VIEWPORT_WITH_COUNT was treated as static, and the
  runtime's vkCmdSetViewportWithCount never reached D3D12. DXVK's present blit then
  drew nothing, so D3D11 swapchain windows showed black. Applications that use the
  count variants were affected in the same way.
- Verified with a Vulkan replica of DXVK's present blit (black before, expected
  pixels after) and with tests/run_dxgi_present_test.sh.

## Fixed: empty Composition panel (CUDA and AE's DirectX display)

- Symptom: after creating a composition, the Composition panel showed only the
  panel background. Panels and the timeline updated normally.
- Cause: with CUDA available, AE shows frames through its DirectX display, which
  passes images between CUDA and Direct3D 12. The CUDA bridge in the prefix
  (nvidia-libs, forwarding to the Linux libcuda) implements no Direct3D resource
  sharing. Its `cuDeviceGetLuid` also failed until patch 18; with that fixed the
  DirectX display still never presents, so the LUID was not the only gap. AE creates
  the vkd3d-proton
  swapchains for its panels but never presents to them (no vkAcquireNextImageKHR or
  vkQueuePresentKHR during a whole run).
- Evidence: the same empty panel on lavapipe instead of dzn (so not a dzn bug); the
  panel renders correctly when CUDA is hidden from AE, and when CUDA stays available
  but AE's DirectX display is disabled.
- Fix: scripts/ae_prefs.sh sets `DS.DisableDirectXDisplay = true` in AE's Debug
  Database before every start. AE then uses its non-DirectX display and keeps CUDA
  for rendering. `AEGNUX_DISABLE_CUDA=1` is the alternative (software rendering,
  Advanced 3D reported as unsupported).
- Test: tests/run_ae_viewer_test.sh (red solid with Invert must show cyan) passes
  with CUDA on and off, and fails with `AEGNUX_DIRECTX_DISPLAY=1`.
- Effect output was checked with Invert and a solid. Other effects were not checked
  one by one.

## Fixed: cuDeviceGetLuid in the CUDA bridge (patch 18)

- Symptom: `err:nvcuda:wine_cuDeviceGetLuid Failed to retrieve LUID for device 0` in
  every AE and GPUSniffer run.
- Cause: nvcuda finds the adapter LUID through the GPU entry whose Vulkan device UUID
  equals the CUDA device UUID. dzn reported a hash of the PCI IDs as device UUID.
- Fix: for NVIDIA adapters dzn loads libcuda and reports the UUID of the CUDA device
  behind the adapter (same LUID, or else the only CUDA device with the adapter's
  name; WSL's libcuda reports the host LUID, which differs from the LUID D3D12
  reports inside the VM). `DZN_DEBUG=nocudauuid` restores the hashed UUID. Cost: one
  `cuInit` (about 30 ms) per process that enumerates dzn devices on an NVIDIA GPU.
- Effect: nvcuda returns the same LUID as DXGI and vkd3d-proton. On its own it does
  not make Advanced 3D or AE's DirectX display work.

## Advanced 3D (`ADBE Calder`): fixed, needs three things

Advanced 3D used to give solid magenta (255, 0, 255) frames with no error. Output is now
the expected image (tested: a red 300x300 3D solid rotated 40 degrees in a 640x480 comp,
rendered with aerender; the frame has the red square on black and no magenta). Three
independent problems were stacked; the first two hid the third.

1. **A stale Disk Cache served the magenta frame.** AE never called the renderer: the
   media cache reported the frame as `IsOnDisk` and gave back the frame stored by an
   earlier failed render (`BEE_ItemRenderOptions` flags: 0x02 cached, 0x08 render). After
   the other two fixes, empty the disk cache once (`.../AppData/Local/Temp/Adobe/After
   Effects/24.6/Disk Cache - <host>.noindex`, or Preferences > Media & Disk Cache > Empty
   Disk Cache). Frames rendered after the fixes are correct and cache normally.
2. **The prefix had the 2013 `d3dcompiler_47.dll` (6.3.9600).** Calder's engine (bgfx based)
   compiles its `.sc` shaders from `EngineAssets.zip` at run time. Its compute shaders
   failed to compile (`Invalid compute shader with error :`), the frame task threw error
   517 and the render aborted. Adobe's own `AE/CEPHtmlEngine/d3dcompiler_47.dll`
   (10.0.19041.685) compiles them. `winetricks d3dcompiler_47` installs the old one; copy
   Adobe's over it (see manual-installation.md, step 5).
3. **dzn did not implement `vkCmdBindVertexBuffers2`.** DXVK 3.0.1 creates pipelines with
   `VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE` and passes the strides only in
   `vkCmdBindVertexBuffers2(pStrides)`. dzn had the generic stub for that entrypoint and
   ignored the dynamic state, so every draw that reads a vertex buffer used stride 0 and
   drew nothing. Advanced 3D draws its scene and its final composite quad that way, so the
   target kept its magenta clear colour (the engine clears intermediate targets to magenta
   as a "not written" marker). A standalone D3D11 test showed it: a vertex-buffer draw
   left the target at its clear colour, while `SV_VertexID` draws and texture sampling
   worked. Fixed by patch 19.
   - Do not use a `winevulkan.so` whose 64-bit `vkCmdBindVertexBuffers2` thunk was changed to
     call the v1 host function (a workaround for the missing dzn entrypoint). It drops the
     strides and brings the problem back. The unmodified runner file is correct once dzn has
     patch 19.

How it was found (kept short; details in `docs/technical-note.md`): a BEE probe on the
render path showed no `PR_NewRender` call and the media cache flags; with the cache empty,
`PR_Render` ran and Calder logged the shader error; a host-side Vulkan layer then showed
the composite pass (`draw verts=6` into a magenta-cleared 640x480 image, blending off)
and the vertex buffer holding a valid fullscreen quad, and dzn received v1 binds with
stride 0.

Still open for Advanced 3D: nothing known with this scene. More complex scenes (lights,
shadows, models, environment textures) were not tested. The CUDA/D3D interop gaps in the
nvcuda bridge (`cuGraphicsD3D11RegisterResource` returns CUDA_ERROR_NOT_SUPPORTED) were
not exercised by this scene. Shared D3D11 textures between two devices are not coherent
under DXVK on Wine here (a standalone test: the second device never sees the first one's
writes, and `DxvkError` with keyed mutexes); AE did not hit this in the tested scene.

Earlier notes in this file about the plugin scan ("No loaders recognized this plugin"),
the missing D3D11 work in the apitrace and the ruled-out feature levels did not turn out to
be the cause: the renderer loads and runs, and the Ignore flag does not matter.

## Not a dzn issue: D3D11 clear-only frames present black

- A D3D11 swapchain test that only clears the backbuffer and presents shows black,
  with dzn and equally with lavapipe. A staging copy and Map of the backbuffer makes
  the presents correct. This is DXVK behaviour, not a driver bug. The regression
  test keeps the copy for this reason. Applications that draw are not affected.

## AE tips and the Home screen reappear in test runs

- AE saves its preferences only when it quits normally. Test scripts stop AE with
  `wineserver -k`, so first-run tips ("Properties Panel", "Review workspace") come
  back in every such session. Quit AE normally to keep their state.

## openSUSE under WSL: Xvfb conflicts with the WSL pattern

- `zypper install xorg-x11-server-Xvfb` stops with a conflict with
  `patterns-wsl-tmpfiles` (that package links `/tmp/.X11-unix` to WSLg's folder). Removing the
  pattern would break WSLg's X11 sockets, so do not take the "deinstall" answer. Only the
  tests need Xvfb. What worked on Tumbleweed: install its libraries
  (`zypper install 'libpixman-1.so.0()(64bit)' 'libXfont2.so.2()(64bit)' 'libXdmcp.so.6()(64bit)'
  'libXau.so.6()(64bit)' xkbcomp xkeyboard-config`), download the package with `zypper download
  xorg-x11-server-Xvfb`, unpack it with `rpm2cpio ... | cpio -idm` and copy `usr/bin/Xvfb` to a
  folder in your `PATH`.

## Untested platforms

- Native Linux hosts: the scripts detect them (no dzn, host Vulkan and GL drivers,
  distribution-specific install hints in doctor.sh), but nothing was run there.
- Under WSL2 the installer and every test were run on fresh images of Ubuntu 24.04,
  Debian 13, Fedora 44, Arch Linux and openSUSE Tumbleweed (see the README table). Other
  WSL distributions (Ubuntu 22.04 and 26.04, Debian 12, Rocky and Alma, Leap, Kali, ...) use
  the same four package families but were not run.

## Open: playback stops after the first preview

- Symptom: RAM preview (space) moves the playhead for about 1 to 3 seconds of comp time and
  then stops. Later previews in the same session may not move at all. The stop key works,
  and AE logs `DoPreview_Complete` for every job.
- The wait: a worker thread that `AfterFXLib.dll` creates while AE starts its audio and video
  renderers (`AudioRendererImpl Init starting up`, about 11 seconds after start in a
  timestamped run) waits for a critical section inside `AfterFXLib.dll` (image offset
  `0x209F0C8`). The Wine log shows it as `wait timed out ... blocked by <main thread>`. It
  appears in every run listed below.
- The owner: the main thread. Right after it creates the worker (call site `AfterFXLib.dll`
  offset `0x3DCC1C`), it enters a message loop called from `AfterFXLib.dll` (offset
  `0x3C6F2C`). Inside that loop it processes `WM_TIMER` and `WM_PAINT` and does not release
  the section. AE's normal loop (`dvaui.dll`, offset `0x5FE543`) runs again only at shutdown.
- Relay logs: `wine.inf` writes a `RelayExclude` list into the prefix. It includes
  `RtlEnterCriticalSection`, `RtlTryEnterCriticalSection` and `RtlLeaveCriticalSection`, so
  relay logs show no critical-section calls. `doctor.sh` warns about it.
- Stop position in seconds of comp time, first play and later plays. The wait was present in
  every run:
  - standard setup: 1.1 to 1.3, then no movement
  - `dxgi.hideNvidiaGpu = False`: 1.13
  - CUDA off (`AEGNUX_DISABLE_CUDA=1`, which also sets `DZN_DEBUG=nocudauuid`): 2.5 and 5.4;
    2.6 and 2.6; 2.57 and 5.47
  - Wine builtin Direct3D (`d3d10core`, `d3d11`, `d3d12` and `dxgi` loaded as builtin, checked
    with a `loaddll` trace), no DXVK, vkd3d-proton, dzn or CUDA bridge: 2.6 and 5.5
  - process pinned to one CPU (`taskset -c 0`): 1.03, 1.13, 1.10
  - `mmdevapi` disabled: 1.17, 1.27, 1.17
  - `Player.xRendererEntryRefactor=false`: 1.13
  - `AE.UseBigMutexR=false`: 1.20, 1.27, 1.23
  - `AE.DeadlockDetectionEnabledR=true`: 1.23, 1.30, 1.17; AE logged no lock diagnostics
  - WinTab32 disabled: 1.17
  - GPU renderer and DirectX display off: 2.37 and 2.33 (the first play did not move)
  - multithreaded rendering, read-ahead, speculative rendering and blit queue off: 1.10
- Status: the cause is not known, and what the worker waits for is not known. The patch series
  does not trigger the wait: it is also present with builtin Direct3D, where no dzn code runs.

## Open: patch 15 advertises features and extensions without tests

- Patch 15 changes one file, `src/microsoft/vulkan/dzn_device.c` (24 added lines). It sets
  these to true:
  - features: `fullDrawIndexUint32`, `tessellationShader`, `dualSrcBlend`, `logicOp`,
    `multiViewport`, `robustImageAccess`, `robustImageAccess2`, `robustBufferAccess2`,
    `inlineUniformBlock`, `nullDescriptor`, `shaderDemoteToHelperInvocation`, `maintenance5`,
    `maintenance6`, `depthClipEnable`, `transformFeedback`, `texelBufferAlignment`
  - extensions: `KHR_pipeline_library`, `KHR_load_store_op_none`, `EXT_robustness2`,
    `KHR_external_memory_capabilities`, `KHR_external_semaphore_capabilities`,
    `KHR_external_fence_capabilities`
  - the Windows external memory and semaphore extensions are set to false
- None of these was tested one by one. Whether dzn implements each one was not checked. A
  wrong advertisement can give wrong output or a GPU hang.
- Next step: test each flag with DXVK 3.0.1 (AE playback and the GPUSniffer result 529), and
  remove the ones that fail.
