# Known issues and limitations

Status date: 2026-10-25. Patch numbers refer to `patches/`.

## Stubs and partial implementations

- **VK_EXT_transform_feedback is a stub (patches 09 and 23).** The entrypoints exist and do
  nothing: stream output is dropped, not emulated, so an application that writes through transform
  feedback (D3D11 stream output in DXVK, D3D12 stream-output targets in vkd3d-proton) gets nothing in
  its buffers. The extension has to stay: vkd3d-proton refuses to create a D3D12 device without it
  (it checks `transformFeedbackQueries`), while DXVK 3.0.1 treats it as optional. Since patch 23 dzn
  prints one line the first time an application uses it ("dzn: VK_EXT_transform_feedback is not
  implemented: stream output is dropped"), so the gap shows in the log and not only in a wrong
  picture; `tests/run_xfb_stub_test.sh`. Real stream output (a lowering in the shader compiler and
  D3D12 stream-output targets) is not done.
- **inlineUniformBlock is advertised (patch 15) but not implemented.**
  `tests/run_descriptor_features_test.sh`: a descriptor pool with an inline uniform block binding
  refuses the allocation (`VK_ERROR_OUT_OF_POOL_MEMORY`). DXVK 3.0.1 lists the feature as required
  (`dxvk_device_info.cpp`), but it creates an inline uniform block layout only when
  VK_EXT_descriptor_buffer is available (`createSpecDataSetLayout`; dzn does not expose that
  extension) and uses a plain uniform buffer otherwise. vkd3d-proton switches the feature off
  (`device.c`). So nothing in this stack allocates an inline uniform block; an application that does
  gets an error.
- **Robust buffer and image access (patches 15 and 22).** `tests/run_robustness_test.sh` checks
  robustBufferAccess2 (storage and uniform buffer descriptors whose range is smaller than the buffer),
  robustImageAccess2 (out-of-bounds `imageLoad` and `imageStore`) and nullDescriptor (null buffers,
  storage and sampled images, texel buffers; null samplers are not allowed and were not tested).
  All pass. The test found that dzn reported 0 for `robustStorageBufferAccessSizeAlignment` and
  `robustUniformBufferAccessSizeAlignment`, which is not a valid value and told applications that
  ranges are checked exactly, while dzn rounds a uniform buffer range up to 256 bytes (the Direct3D 12
  constant buffer granularity) and a storage buffer range up to a dword. Patch 22 reports 4 and 256:
  accesses inside the rounded range return the data, accesses past it return zero and writes are
  dropped.
- **Tessellation (patches 15, 24 and 25).** Patch 15 turns `tessellationShader` on, because DXVK
  derives Direct3D 11 feature level 11_0 from it. It was not enough: dzn reported every
  tessellation limit as 0 (DXVK clamps every factor to `maxTessellationGenerationLevel`; patch 24
  reports the limits the Vulkan specification requires), and the hull shader that DXVK generates
  reads `gl_PatchVerticesIn`, for which the translation to DXIL has no instruction. That ended in
  `Unimplemented intrinsic instruction: load_patch_vertices_in` and then in exception 0xc0000005
  inside `vkCreateGraphicsPipelines` (the `unreachable()` behind the message is not compiled into a
  release build), so any D3D11 program with a hull shader crashed. Patch 25 turns it into a
  constant of the pipeline (the patch size for the control shader, the control points that the
  control shader outputs for the evaluation shader). `tests/run_d3d11_tessellation_test.sh` draws
  one tessellated quad for the factors 1, 8 and 64: 2704 red pixels each time (about 2700 are
  expected). Open: about 1 run in 12 ends with `nested exception on signal stack` at process exit,
  after the right frame (3 of 36 runs; 0 of 48 with `DXVK_STATE_CACHE=0` or with one DXVK compiler
  thread; a D3D11 program without tessellation, the DXGI present test, 0 of 12); the cause was not
  examined and After Effects does not use tessellation. Only this one hull and domain shader pair
  was tried, so other patch sizes and domains are not covered.
- **VkFormatProperties3 (patch 14)** copies only the three legacy masks. Other 1.3
  fields are not reported separately.
- **Sparse resources** are not supported; the sparse memory requirement queries
  return zero entries.
- **Sample locations and other dynamic state** beyond what dzn already handled are not
  covered by tests. (Dynamic vertex strides work since patch 19.)
- **Shared timeline semaphores (patch 21) are an emulation.** The Direct3D 12 layer under dzn
  cannot open a shared fence, so a semaphore that is exported or imported as an opaque fd keeps its value
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

## Fixed: new text layers were empty when many fonts are installed (default font)

- Symptom: after a desktop (KDE with the Noto families: 466 fonts instead of 195) was installed
  on the test machine, `tests/run_ae_advanced3d_viewer_test.sh` failed (136 to 144 orange pixels
  instead of 41212): the 3D text was invisible. After Effects kept running and nothing was logged.
  Every new text layer, 2D or 3D, looked empty.
- Cause: After Effects gives a new text layer the default font `MyriadPro-Regular`. Wine did not
  have it, and After Effects then took a font by rules of its own: with 225 font families visible
  it took `NotoSansSignWriting-Regular`, which has no Latin letters (the box of the text measured
  0 x 0); with 33 families it took DejaVu Sans (578 x 149).
- Not the cause: the dzn patches (the test passed again with patches 22 and 23 reverted and failed
  with them restored; removing the Noto fonts made it pass), and a fontconfig alias that prefers
  DejaVu Sans (no effect).
- Fix: `ae_prefs.sh` copies After Effects' own `pdfl/Fonts/MyriadPro-Regular.otf` (shipped in the
  installation) into the prefix's Fonts folder before every start. The default font is Myriad Pro
  again (box 498 x 138 with 226 families). `AEGNUX_DEFAULT_FONT=0` leaves the prefix alone;
  `doctor.sh` says whether the file is there; `tests/run_ae_text_test.sh` measures the box of a new
  text layer and fails below 100 x 50 (NotoSansSignWriting without the file, Myriad Pro with it).

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
- Cause: Wine makes a GPU of every EGL device. Mesa lists the software `vgem` render node of
  the Direct3D 12 route's display stack as a second device, and when the user can open `card0` it
  starts that device (software fallback `kms_swrast`). Wine then reported a second adapter, `D3D12 (NVIDIA GeForce RTX
  4060 Ti)` with a generic driver version (35.0.10.1000), next to the real one, and AE's
  NVIDIA rules matched it. (Wine source: `init_egl_devices` in `dlls/win32u/opengl.c`.)
- Fix: `aegnux_env` sets `MESA_LOADER_DRIVER_OVERRIDE=d3d12` on the Direct3D 12 route. Mesa cannot build
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
- Checked on Ubuntu 24.04 on the Direct3D 12 route with the OpenGL display on: the viewer test goes from
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
  name; on the Direct3D 12 route libcuda reports the host LUID, which differs from the LUID D3D12
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
  `ID3D12Device::OpenSharedHandle(IID_ID3D12Fence)` fails with E_INVALIDARG on the Direct3D 12 route
  for every combination of fence flags, devices and duplicated handles, while shared heaps and shared
  committed textures open fine. That Direct3D 12 layer can create a shared fence handle but not open one.
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
- Repeats on the same machine (the emulation uses a helper thread, so a race would show as an
  occasional failure): `run_semaphore_share_test.sh` 30 of 30 runs, `run_d3d11_shared_texture_test.sh`
  6 of 6.
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

## Untested platforms

- Hosts with a native GPU driver (the host-driver route): the scripts detect them (no dzn, host
  Vulkan and OpenGL drivers, distribution-specific install hints in doctor.sh), but nothing was run
  there.
- The installer and every test were run on fresh images of Ubuntu 24.04, Debian 13, Fedora 44,
  Arch Linux and openSUSE Tumbleweed on the Direct3D 12 route (see the README). Other releases and
  derivatives (Ubuntu 22.04 and 26.04, Debian 12, Rocky and Alma, Leap, Kali, ...) use the same
  four package families but were not run.

## Fixed: RAM preview played at a fifth of real time (glibc `rep movsb`)

- Symptom: RAM preview (space) moved the picture of the Composition panel at about 7 frames a
  second for a 30 fps comp, a fifth of real time (8 s of a 10 s comp after 40 s). Earlier notes
  called it "playback stops after 1 to 3 seconds"; that came from another measurement. The
  picture of the panel is the reference, and the red preview needle of the timeline follows it
  (see "RAM preview: the timeline and the sound server" below). `tests/run_ae_ram_preview_test.sh`
  follows both in screenshots.
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
- Fix: `aegnux_env` sets `GLIBC_TUNABLES=glibc.cpu.x86_rep_movsb_threshold=0x40000000` on the
  Direct3D 12 route, so glibc's `memcpy` stays on its vector loops for copies up to 1 GiB.
  `AEGNUX_REP_MOVSB=1` keeps glibc's default. On the test machine the preview ran at 0.20 to 0.22
  times real time before and at 0.99 after (comp 1280x720, 30 fps, 10 s, Gaussian Blur on the
  moving layer). `glibc.cpu.hwcaps=-ERMS,-FSRM` gave the same speed, but it turns the fast string
  instructions off for every copy, so it was not used.
- Not known: why `rep movsb` is so slow on these mappings. The test machine has an Intel Core
  i5-12400F (flags `erms` and `fsrm`), kernel 6.18.54.1 and glibc 2.39. Other CPUs and
  hosts were not tried. The setting only moves copies from `rep movsb` to glibc's vector loops.

## RAM preview: the timeline and the sound server

### The red needle (not a fault)

- While a RAM preview plays, the blue current-time indicator stays where the preview started
  and a thin red needle runs along the ruler in step with the picture; `comp.time` read from a
  script stays at the start too. When the preview stops, the needle disappears and the blue
  indicator jumps to the frame where the preview stopped. After Effects keeps two times: the
  time of the picture ("Preview Time") and the time of the indicator ("Current Time"); the
  tooltip of the time field in the Composition panel says "Preview Time (Click to change Current
  Time)". Earlier notes here called this "the playhead does not move during a RAM preview" and an
  open issue: they followed the blue line only, and the test that looked for it found it at the
  start in every run.
- Measured: `tests/run_ae_ram_preview_test.sh` follows the red needle. It moved 975 to 982 px of
  the 987 px that the 10 s comp spans on the ruler and was 0.03 to 0.04 s from the picture on
  average (124 to 186 samples per run). Breakpoints in After Effects (a private copy, nothing
  changed): every tick of the preview (15 a second, two frames each) calls `CItem::UpdateNeedle`
  with the new time, the preview start logs "Start: taking over the time needle", and the stop
  removes the "manual needle".
- Why it is not a fault, from the code: Ghidra on a private copy of `AfterFXLib.dll` (byte for byte
  the file of the Windows installation, so the same code runs on Windows). `CItem::RealtimeNeedle_Move`
  takes the time from the system tick count (`RealtimeNeedle_CalcCurrentTime`, `U_TickCount`) and calls
  `CItem::UpdateNeedle`, which (throttled by the preference "Time needle scrub and preview update
  frequency (seconds)") calls the virtual `TimeNeedle_Scrub` of the item, the overlay that is also
  used while the blue indicator is dragged. Nothing in that path sets the current time. The function
  that ends a preview ("Ending Preview Time", "Set Current Time To") does, when the preference
  "When Preview Is Stopped, Set Time To Preview Time" is on, and it is on by default. Adobe's
  community experts describe the same for After Effects on Windows: a red Preview Time Indicator
  moves, the blue current-time indicator stays, and "Move Time to Preview Time" moves it when
  the preview stops. A run of After Effects on Windows itself is the one thing this repository
  does not show.
- The `err:sync:RtlpWaitForCriticalSection ... wait timed out` line in the Wine log (every run)
  belongs to After Effects' WinTab32 tablet thread, which waits for the first pen event, and is
  harmless. `wine.inf` writes a `RelayExclude` list into the prefix that hides critical-section
  calls from relay logs; `doctor.sh` warns about it.

### The classic RAM preview and a comp of 4K

- Classic RAM preview (After Effects renders the whole range into RAM first, then plays it from the
  cache with its audio; the numpad-0 shortcut does that in a default setup, and
  `tests/run_ae_ram_preview_cached_test.sh` switches "Cache Before Playback" on for the Space shortcut
  because a bare Xvfb display has no NumLock): 10 runs with the audio output that `launch_ae.sh` gives
  all passed: cached playback at 0.82 to 1.00 times real time, the needle 0.03 to 0.06 s from the
  picture, the loop repeating. The caching of the 10 s comp takes 2 s. One earlier run, the first one
  after a series of runs against the broken sound output, had shown a picture frozen for 13 s, a
  start at 5 s of the comp, 0.57 times real time and a stop at 9.2 s without a loop; it did not
  come back in the 10 runs that followed, and with no audio device (`AEGNUX_TEST_AUDIO=none`) the same
  test gave 1.00 times real time. With a private PulseAudio null sink (`null`) one run had the
  needle 2.3 s from the picture (one run, not repeated).
- A comp of 3840x2160 and 120 s (`tests/run_ae_ram_preview_heavy_test.sh`), previewed for four
  minutes on a machine with 24 GB: After Effects and Wine grew to 9.7 GB and stayed there (the RAM
  cache stopped growing after about 90 s), the machine kept 13.6 GB available, After Effects used
  about 5700 memory mappings, the picture played at 0.96 times real time from the first pass to the
  repeats, the needle was 0.16 s from the picture, and nothing crashed. (A comp whose whole range
  does not fit in the RAM cache, previewed with Cache Before Playback on, was not tested.)

### Fixed: the sound output of the Direct3D 12 route breaks RAM preview after the first stop

- Symptom: stopping a RAM preview takes a second longer (the red needle is gone after 1.3 s
  instead of 0.2 to 0.3 s), and the next preview does not start: no needle, the picture does not
  move, After Effects stays alive. The first preview itself plays at real time (0.98 times real
  time with a tone layer in the comp). `tests/run_ae_ram_preview_cycles_test.sh` starts and stops
  the preview three times; with `AEGNUX_TEST_AUDIO=host` it fails this way in every run (cycle 1
  stops after 1.3 s, the later cycles do not start).
- Where it happens: the PulseAudio server of the Direct3D 12 route's display stack
  (`/mnt/wslg/PulseServer`), whose only output is an RDP sink (`module-rdp-sink`, a remote desktop
  session's audio). The same cycles with no audio device at all (a `PULSE_SERVER` that refuses
  connections), with a PulseAudio null sink, or with AE's own `dvaaudiodevice.ForceNoDevices`
  ran fine (3 of 3 and 8 of 8 cycles, the needle gone after 0.2 to 0.3 s). An ALSA `null` device
  did not help (Wine's ALSA driver does not use it).
- What After Effects does (a Wine log with `+winmm,+pulse,+mmdevapi`): at its start it opens the
  device through `waveOutOpen` with `CALLBACK_EVENT`; winmm creates a PulseAudio stream (32-bit
  float, 44.1 kHz, stereo, target length 25 ms, request size 10 ms) that starts corked, After
  Effects pauses it at once and queues nine buffers of 8192 bytes, and when a preview starts
  it calls `waveOutRestart`, which uncorks the stream. With the RDP sink the log ends right after
  that start: the server never asks the stream for data again. The audio thread of
  `dvaaudiodevice.dll` sits in `waveOutRestart`, `IAudioClient::Start`, winepulse, waiting for the
  server (stack samples, breakpoints and `winedbg` backtraces on a private copy, no Adobe file
  changed). When the preview stops, the DLL posts a quit message to that thread and polls
  `GetExitCodeThread` every 50 ms; after 20 rounds (one second) it calls `TerminateThread`, and the
  next preview does not start.
- Cause, shown without Wine and without After Effects (`tests/run_pulse_resume_test.sh`, a Python
  program that replays the sequence with libpulse): a stream is created corked and uncorked
  three times, with seven idle seconds between the rounds. Round 1 works (the uncork is answered
  in 2 ms and the stream takes all the data). After the idle time the RDP sink has suspended
  (module-suspend-on-idle waits five seconds), and in rounds 2 and 3 the uncork is answered after
  1.8 to 2.2 s and the stream takes under 1% of the data. The server's other clients are
  affected too: `pactl` timed out while After Effects' stream was open. Streams that start
  uncorked are fine (`pacat` with the same format played for 15 s, a 25 ms target length for
  10 s), so it is neither the format nor the latency: the sink does not resume properly for a
  stream that was created corked while the sink was suspended. After Effects creates its
  stream at its start and uncorks it long after the five seconds.
- Fix: `launch_ae.sh` plays a silent stream (`scripts/sound_keepalive.sh`: 8 kHz mono silence, a
  few KB/s, played by `pacat` or, when that is not installed, by `python3` with
  `scripts/tools/silent_stream.py`) for as long as After Effects runs, so the sink never suspends. The
  sequence then works: every uncork is answered in 2 ms (`run_pulse_resume_test.sh` repeats the
  sequence with the silent stream), the three RAM preview cycles start and stop with the needle
  gone after 0.3 s, and the sound arrives: a recording of the sink's monitor during a preview of a
  comp with a 440 Hz tone layer showed the tone at a peak of 7999 of 8000 for the whole 30 s of
  the preview. It is decided by `aegnux_audio_plan` (`scripts/common.sh`): the silent stream when
  an output of the sound server is an RDP sink (`AEGNUX_SOUND_KEEPALIVE=auto`), nothing for other
  sound servers. With neither `pacat` nor `python3` After Effects is told there is no audio device
  (`dvaaudiodevice.ForceNoDevices`, written by `ae_prefs.sh`; no sound, RAM preview works), and
  `doctor.sh` (Audio) says so. `AEGNUX_AUDIO_DEVICES=0` does that on purpose and
  `AEGNUX_NULL_AUDIO=1` gives After Effects a silent output from a PulseAudio server of its own
  (`scripts/null_audio.sh`). `install.sh` makes sure of `python3` and of `libpulse.so.0` (Wine's
  audio driver links it; without it After Effects plays no sound).
- On the real display (After Effects started with `launch_ae.sh` on the desktop's own X server,
  a comp with a 440 Hz tone layer, three previews of 14 s with 8 s between them, started by the
  Play Current Preview command from a startup script): with the silent stream the picture advanced
  at 1.00 comp seconds per second in every preview, the three previews all started, the current time
  jumped to the stop frame each time, and the tone reached the sound output (peak 7999 of 8000 in
  three bursts). With `AEGNUX_SOUND_KEEPALIVE=0` the first preview played, the second and third never
  started and the picture stayed on the stop frame. A recording of the output's monitor counts as use
  of the output and keeps it from suspending, so a run that records hides the fault (the control run
  has no recording). A second distribution installed on the same machine does not see these streams
  (its sound server socket is another one), so a recording has to come from the distribution that
  runs After Effects.
- Not known: why the RDP sink fails to resume (the sound server of the display stack is not
  examined; the sequence above is a reproduction to report upstream, not reported). PipeWire's
  and PulseAudio's own servers on a machine with a sound card were not tested. After Effects
  has to be started through `launch_ae.sh` (or `aegnux_audio_up` in `common.sh`): a plain
  `wine AfterFX.exe` plays no silent stream.

## Wayland: X11 through XWayland is the tested path

- Setup: `aegnux_wine_driver` (`scripts/common.sh`) picks Wine's display driver. It is `x11` when
  `DISPLAY` is set (XWayland, in a Wayland session) and `wayland` only when `DISPLAY` is not set or
  `AEGNUX_WAYLAND=1`. `ae_prefs.sh` writes the choice to `HKCU\Software\Wine\Drivers`, and
  `aegnux_env` hides `WAYLAND_DISPLAY` from Wine when the driver is `x11`. Without that, a Wine that
  sees both variables takes its Wayland driver on its own.
- Tested: `tests/run_ae_wayland_test.sh` runs After Effects inside sway 1.9 (headless backend,
  XWayland, private sockets, `WLR_RENDERER=pixman`) started so that `WAYLAND_DISPLAY` and `DISPLAY`
  are both set. After Effects loads `winex11.so`, and a `grim` screenshot of the compositor shows
  the rendered comp in the Composition panel (78522 cyan pixels, test passes). A stepwise run showed
  the whole After Effects workspace in the compositor. The test passed in four runs in a row. One
  earlier run, the first after a run in which Wine's Wayland driver had failed to load, showed no
  window within 150 s (its `err.log` held only Wine's start-up lines); it was not reproduced, and
  its cause is not known.
- Wine's own Wayland driver (`AEGNUX_WAYLAND=1`) does not work well enough to be a default:
  - The runner's `winewayland.so` calls `wl_display_create_queue_with_name`, which libwayland 1.23
    added. With libwayland-client 1.22 (Ubuntu 24.04) the driver fails to load; Wine logs "Application
    tried to create a window, but no driver could be loaded" and no window appears. `launch_ae.sh` and
    `doctor.sh` find this with `ldd -r` and say so.
  - With a libwayland-client 1.23.1 from Debian trixie in `LD_LIBRARY_PATH` (nothing installed
    system-wide), After Effects starts and draws its workspace in sway, but shows the warning
    "Advanced 3D is not supported by the current hardware" at once. That warning does not appear on the
    X11 route. The cause was not examined (likely the OpenGL or GPU detection through Wine's Wayland
    driver).
- Not tested: GNOME and KDE Plasma sessions, fractional scaling, HiDPI and several monitors.
- Test environment note: wlroots compositors refuse to start XWayland when `/tmp/.X11-unix` lacks the
  sticky bit (a folder that is a mount of another system's socket directory has none; a desktop
  distribution creates it with mode 1777). The test then fails with a message that names the folder.

## Heavy memory use: a crash with nearly full memory was not reproduced

- The README of AEGNUX lists "potential crashes under heavy RAM usage (need to tweak your system
  config)" as a known downside. The system setting that fits is `vm.max_map_count`: the kernel limit
  of memory mappings per process is 65530 on many systems, and Wine programs with a large working
  set use many mappings.
- Measured: After Effects used at most about 5800 mappings at up to 3 GB resident memory in the
  first tests (the limit of the test system was 1048576). `tests/run_ae_ram_preview_heavy_test.sh`
  then previewed a 3840x2160, 120 s comp for four minutes: After Effects and Wine grew to 9.7 GB
  (the machine has 24 GB), stayed there while the RAM cache was full, used about 5700 mappings, played
  at 0.96 times real time and did not crash; the machine kept 13.6 GB available. A crash with nearly
  full memory was not reproduced, so the limit is a likely cause, not a proven one.
- `scripts/doctor.sh` warns when `vm.max_map_count` is below 1048576, and the README gives the
  `sysctl` line that raises it.

## Patch 15 advertises features and extensions: what each is for and what was checked

Patch 15 changes one file, `src/microsoft/vulkan/dzn_device.c` (24 added lines), and sets the
features and extensions below to true; the Windows external memory and semaphore extensions are
set to false. DXVK 3.0.1 and vkd3d-proton refuse to create a device without some of them, so they
cannot just be switched off. What needs each one (from their sources) and which test looks at it:

| Feature or extension | Needed by | Checked |
|---|---|---|
| `nullDescriptor`, `robustBufferAccess2`, `robustImageAccess2` | DXVK (the first two) and vkd3d-proton (all three) | `tests/run_robustness_test.sh`: all pass (patch 22 came out of it) |
| `tessellationShader` | DXVK takes feature level 11_0 from it | `tests/run_d3d11_tessellation_test.sh` (patches 24 and 25 came out of it) |
| `transformFeedback` | vkd3d-proton (`transformFeedbackQueries`); DXVK uses it if there | `tests/run_xfb_stub_test.sh`: it is a stub that warns (patch 23) |
| `inlineUniformBlock` | DXVK lists it as required | `tests/run_descriptor_features_test.sh`: not implemented, nothing in this stack allocates one |
| `dualSrcBlend`, `fullDrawIndexUint32`, `multiViewport`, `depthClipEnable`, `shaderDemoteToHelperInvocation` | DXVK | not one by one; the GPUSniffer run, the viewer, Advanced 3D and the effects tests create DXVK devices with all of them on and render correctly |
| `logicOp`, `robustImageAccess`, `texelBufferAlignment`, `maintenance5`, `maintenance6` | no known requirement | not tested |
| `KHR_pipeline_library`, `KHR_load_store_op_none`, `EXT_robustness2`, `KHR_external_memory_capabilities`, `KHR_external_semaphore_capabilities`, `KHR_external_fence_capabilities` | the extension of the same name in the stack above | not one by one |

A wrong advertisement can give wrong output or a GPU hang. The two that turned out to be wrong in
use (tessellation limits and `gl_PatchVerticesIn`, robust access size alignments) are fixed; the
untested rows are the remaining open item.
