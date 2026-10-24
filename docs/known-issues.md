# Known issues and limitations

Status date: 2026-10-24. Patch numbers refer to `patches/`.

## Stubs and partial implementations

- **VK_EXT_transform_feedback is a stub (patch 09).** The entrypoints exist and do
  nothing. Stream output is dropped, not emulated, so any effect that depends on
  transform feedback renders incorrectly. The extension is advertised only so that
  vkd3d-proton and DXVK accept the device.
- **inlineUniformBlock is advertised (patch 15) but not implemented; nullDescriptor works
  for buffers.** `tests/run_descriptor_features_test.sh` shows it: a storage buffer and a
  uniform buffer descriptor written with VK_NULL_HANDLE read as zero, but a descriptor pool
  with an inline uniform block binding refuses the allocation (`VK_ERROR_OUT_OF_POOL_MEMORY`).
  Null image, sampler and texel buffer descriptors were not tested. DXVK 3.0.1 refuses to
  create an adapter without these bits, so they stay on. An application that really uses
  inline uniform blocks gets an error.
- **Robustness bits (patch 15)** robustImageAccess, robustBufferAccess2,
  robustImageAccess2 and EXT_robustness2 are advertised without a dedicated test.
  D3D12's default out-of-range behaviour is assumed to match.
- **VkFormatProperties3 (patch 14)** copies only the three legacy masks. Other 1.3
  fields are not reported separately.
- **Sparse resources** are not supported; the sparse memory requirement queries
  return zero entries.
- **Sample locations and other dynamic state** beyond what dzn already handled are not
  covered by tests. (Dynamic vertex strides work since patch 19.)
- **Shared timeline semaphores (patch 21) are an emulation.** WSL's Direct3D 12 cannot open
  a shared fence, so a semaphore that is exported or imported as an opaque fd keeps its value
  in a memfd page; see "Fixed: crash in the Advanced 3D viewer (patch 21)". CPU signals and
  waits, queue signals and queue waits cross between devices, but a queue wait for a value
  that another device signals later blocks the submitting thread until it arrives, and a
  semaphore cannot be shared with another process.

## Workarounds (labelled in the code and commit messages)

- **apiVersion raised to 1.3 (patch 04).** An application that asks for an older
  apiVersion gets the device entrypoints gated at 1.3 by the loader. dzn raises the
  instance's app apiVersion and prints one line to stderr. The aegnux layer in
  `scripts/apiver_layer/` does the same from outside the driver. It is optional
  (`AEGNUX_APIVER_LAYER=1`): with the previous default layer path it was never
  loaded and AE still worked, so patch 04 alone is enough.
- **KHR_external_memory_win32 and KHR_external_semaphore_win32** are turned off in
  `_WIN32` builds (patch 15). This is not exercised on Linux, where Wine builds its Win32
  variants on dzn's `KHR_external_memory_fd` and `KHR_external_semaphore_fd`.

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

Scene coverage (`tests/run_ae_advanced3d_scene_test.sh`, one After Effects run, all six
scenes pass on AE 24.6.2 with Calder and CUDA): two-node cameras, point lights, shadows from
an Environment light, extruded 3D text, image-based lighting from an Environment light, and a
30-solid stress scene. Every frame is valid (no magenta, not one colour). Imported 3D models
(GLTF/GLB/OBJ/FBX) were not tested.

Two AE 24.6 behaviours look like renderer failures but are not. Only an Environment light
(`LightType.ENVIRONMENT`) casts shadows in Advanced 3D; the `Casts Shadows` property of a point
or spot light is hidden, so scripting it fails. The old Layer > Environment Layer switch and
the `ADBE Reflection Coefficient` material property belong to the Cinema 4D / ray-traced
renderers; they do not affect Advanced 3D. The earlier scene test used those two features and
reported "not scriptable"; the fixed test uses an Environment light with `Casts Shadows` and
`Light Intensity` instead.

The `Casts Shadows` menu of a layer: 2 is "Only" (the layer is not drawn, only its shadow), 1 and 3
draw the layer and it casts a shadow. The scene test set the text to 2, so the text of the shadow
scene was never drawn (the shadow was there, and the test only measured the shadow). It sets 1 now
and checks that the caster is drawn.

The CUDA/D3D interop gaps in the nvcuda bridge (`cuGraphicsD3D11RegisterResource` returns
CUDA_ERROR_NOT_SUPPORTED) were not exercised by these scenes.

An earlier version of this section said that shared D3D11 textures between two devices are not
coherent under DXVK on Wine. That was a test artifact: the test cleared the texture with
`ClearRenderTargetView`, and DXVK holds a clear back until the image is used on the same device,
so the second device read zeros. A texture that is written with `UpdateSubresource`, a draw or a
copy is read correctly by the second device. The keyed mutex case did fail, and it is what crashed
the Advanced 3D viewer at 1080p: see the next section.

## Fixed: crash in the Advanced 3D viewer (patch 21)

- Symptom: with an Advanced 3D comp in the Composition panel (1920x1080, extruded text, lights and
  an Environment light with shadows), After Effects stopped a few seconds after a full-quality
  render, when the Draft 3D button of the viewer was clicked. The error box said `After Effects
  error: Crash in progress. Last logged message was: <828> <3D.Tiling> <5> Tile size Y: 689` and
  offered to save the project. The Wine log had no exception line, the kernel log no out-of-memory
  kill and the DXVK log no error. The process had grown from 3 to 9 GB, which made it look like
  "AE crashes when memory fills", but no limit was reached. The message is only the last line AE
  logged before the crash; it is not the cause. `saveFrameToPng` of the same comp never crashed.
- Where it died (no disassembly of Adobe code): AE's crash report (Sentry breadcrumbs in
  `AppData/Local/Temp/Adobe/After Effects/24.0/SentryIO-db`) put the error box on the display
  thread, called from the unhandled-exception filter. `winedbg` attached to the running process
  and printed that thread's stack: `RaiseException` called by `d3d11.dll` (DXVK 3.0.1) with the
  code 0x20474343 (a MinGW C++ `throw`), through `__cxa_throw`, `DxvkFence::DxvkFence` and
  `DxvkDevice::createFence`, from the code of `ID3D11Device1::OpenSharedResource1`. Reading the
  string that the throwing block loads gives the message "Failed to import timeline semaphore".
  AE's frames are MSVC code and do not catch a GCC exception, so the filter ran.
- Why DXVK throws: when a shared texture comes with a keyed mutex, `OpenSharedResource1` imports
  the semaphore of the mutex with `vkImportSemaphoreWin32HandleKHR` and does not wrap
  `createFence` in its `try`/`catch` (the later texture creation is wrapped). That is a bug in
  DXVK 3.0.1 that only shows when the driver refuses the import. Wine's `win32u` implements
  the call on the host driver's `vkImportSemaphoreFdKHR`, and dzn answered
  `VK_ERROR_INVALID_EXTERNAL_HANDLE` to every import, even of an fd it had just exported
  (a native Vulkan test shows it without Wine). The reason is below dzn:
  `ID3D12Device::OpenSharedHandle(IID_ID3D12Fence)` fails with E_INVALIDARG on WSL for every
  combination of fence flags, devices and duplicated handles, while shared heaps and shared
  committed textures open fine. WSL's Direct3D 12 can create a shared fence handle but not open one.
- Why the viewer needs it: the viewer shows the frames of Advanced 3D through shared D3D11
  textures with a keyed mutex (Wine logs `NtGdiDdDDICreateKeyedMutex2` and
  `NtGdiDdDDIOpenSyncObjectFromNtHandle` when AE creates the first one). Plain shared textures
  (no keyed mutex) worked all along.
- Fix: patch 21 changes `dzn_sync.c` (and the two queue functions that wait for and signal a
  semaphore). A timeline semaphore that is exported as an opaque fd now keeps its highest
  signalled value in one page of a memfd; the exported fd is the memfd, and an importer maps the
  page and starts a fence of its own device at the shared value. CPU signals raise the value, CPU
  waits, `vkGetSemaphoreCounterValue` and queue waits look at the page as well as at the fence, a
  small helper thread copies the value of a GPU signal into the page when the fence reaches it, and
  a queue wait for a value that nobody has signalled yet blocks the submitting thread until it
  arrives. The patch also fixes a double release: a failed import released the fence before it
  made the new one, so destroying the semaphore released it a second time.
- Tests (each fails without the patch and passes with it, same machine, same DXVK):
  `tests/run_semaphore_share_test.sh` (two Vulkan devices share a timeline semaphore: import
  refused with `VK_ERROR_INVALID_EXTERNAL_HANDLE` before, 17 checks pass after),
  `tests/run_d3d11_shared_texture_test.sh` (two D3D11 devices share a texture with and without a
  keyed mutex: the keyed case ends with `terminate called after throwing an instance of
  'dxvk::DxvkError'` before, both read the written pixel after) and
  `tests/run_ae_advanced3d_viewer_test.sh` (After Effects shows a 1080p Advanced 3D scene and the
  test clicks Draft 3D twice: an error box before, no box and the 3D text on screen after).
- A DXVK 3.0.1 rebuilt with a `try`/`catch` around `createFence` (`OpenSharedResource1` then returns
  E_FAIL) also keeps AE alive after the click. That is not a fix for the viewer, which needs the
  import to work, but upstream DXVK should catch the exception; it is not part of this repository.

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

## Fixed: RAM preview played at a fifth of real time (glibc `rep movsb`)

- Symptom: RAM preview (space) moved the picture of the Composition panel at about 7 frames a
  second for a 30 fps comp, a fifth of real time (8 s of a 10 s comp after 40 s). Earlier notes
  called it "playback stops after 1 to 3 seconds"; that came from another measurement. The
  picture of the panel is the reference now, because the playhead of the timeline does not move
  at all (see the open issue below). `tests/run_ae_ram_preview_test.sh` follows the picture in
  screenshots.
- Where the time went: the "Display Thread" of `AfterFX.exe` used 95 % of a CPU, the main thread
  8 %. A ptrace sampler (instruction pointer and stack words only, no disassembly of Adobe code)
  put 89 % of the samples on one instruction in glibc, the `rep movsb` of
  `__memmove_avx_unaligned_erms`. The callers on the stack are Mesa's `util_copy_rect`,
  `util_copy_box`, `u_default_texture_subdata` and `st_TexSubImage`: every frame that After
  Effects hands to `glTexSubImage2D` is copied into the d3d12 upload buffer one row at a time
  (rows of 4 to 8 KB). Source and destination are `/dev/zero (deleted)` mappings (shared
  anonymous memory: two 4 MB frame buffers and a 3 MB upload buffer). The thread had no page
  faults and 2 % system time, so the copy itself is slow, not the allocation.
- Measured inside the running After Effects (an `LD_PRELOAD` shim that times the 2 KB to 64 KB
  `memcpy` calls and changes the copy loop every 4 s): `rep movsb` 43 to 47 MB/s, a plain AVX2
  loop 2.2 GB/s, AVX2 with non-temporal stores 1.7 to 1.9 GB/s, non-temporal loads 0.8 GB/s, a
  64-bit loop 0.42 GB/s. The preview ran at 0.99 times real time while any loop other than
  `rep movsb` was active.
- Fix: `aegnux_env` sets `GLIBC_TUNABLES=glibc.cpu.x86_rep_movsb_threshold=0x40000000` under
  WSL, so glibc's `memcpy` stays on its vector loops for copies up to 1 GiB.
  `AEGNUX_REP_MOVSB=1` keeps glibc's default. On the test machine the preview ran at 0.20 to 0.22
  times real time before and at 0.99 after (comp 1280x720, 30 fps, 10 s, Gaussian Blur on the
  moving layer). `glibc.cpu.hwcaps=-ERMS,-FSRM` gave the same speed, but it turns the fast string
  instructions off for every copy, so it was not used.
- Not known: why `rep movsb` is so slow on these mappings. The test machine has an Intel Core
  i5-12400F (flags `erms` and `fsrm`), WSL2 kernel 6.18.54.1 and glibc 2.39. Other CPUs and
  hosts were not tried. The setting only moves copies from `rep movsb` to glibc's vector loops.

## Open: the playhead of the timeline does not move during a RAM preview

- Symptom: while a RAM preview plays (the Composition panel shows the motion) the blue
  playhead of the timeline stays at the start, and `comp.time` read from a script stays at the
  start too. The green cache bar fills. `tests/run_ae_ram_preview_test.sh` prints "timeline
  playhead: moved 0 px" in every run, at every playback speed.
- The wait that the Wine log shows (`err:sync:RtlpWaitForCriticalSection ... wait timed out ...
  blocked by <main thread>`, in every run) is not the cause. Reading the code of `AfterFXLib.dll`
  (objdump of the 15 places that use the section at image offset `0x209F0C8`, the import table
  and the strings, no Adobe file changed) shows that it belongs to AE's WinTab32 tablet code.
  The init function (offset `0x3DCBC0`, called from `0x5E393D`) creates the polling thread
  suspended with `CreateThread`, takes the section on the main thread and resumes the thread,
  which blocks on it. The section is released by the first call of the pen reader (`0x3DCD00`,
  called from the pen event handler `0x3CDE60`), and the same cluster of functions has the
  `WinTab32.dll` string. Without a tablet and a pen event the thread stays blocked; that is the
  design, and it is the same on Windows, where nothing logs it. Earlier notes here took the
  wait and a message loop of the main thread (offset `0x3C6F2C`) for the cause of the frozen
  playhead; that loop was not examined further.
- Relay logs: `wine.inf` writes a `RelayExclude` list into the prefix. It includes
  `RtlEnterCriticalSection`, `RtlTryEnterCriticalSection` and `RtlLeaveCriticalSection`, so
  relay logs show no critical-section calls. `doctor.sh` warns about it.
- The wait was present with every variant tried: standard setup, `dxgi.hideNvidiaGpu = False`,
  CUDA off (`AEGNUX_DISABLE_CUDA=1`), Wine's builtin Direct3D without DXVK, vkd3d-proton, dzn or
  the CUDA bridge, the process pinned to one CPU, `mmdevapi` disabled, `Player.xRendererEntryRefactor=false`,
  `AE.UseBigMutexR=false`, `AE.DeadlockDetectionEnabledR=true` (AE logged no lock diagnostics),
  WinTab32 disabled, the GPU renderer and DirectX display off, and multithreaded rendering,
  read-ahead, speculative rendering and the blit queue off. The patch series does not
  trigger the wait: it is also present with builtin Direct3D, where no dzn code runs.
- Status: not known whether this loop is why the playhead does not repaint, and what the worker
  waits for is not known either.

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
