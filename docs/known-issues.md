# Known issues and limitations

Status date: 2026-10-18. Patch numbers refer to `patches/`.

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
- Advanced 3D: see "Open: Advanced 3D renders solid magenta frames".

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

## Open: Advanced 3D renders solid magenta frames

- Symptom: with the comp renderer set to Advanced 3D (`ADBE Calder`), the
  Composition panel and render queue output are solid magenta (255, 0, 255), and a
  1920x1080 frame "renders" in about 130 ms. AE shows no error. Classic 3D in the
  same project gives the expected image. With CUDA hidden, AE reports "Advanced 3D
  is not supported by the current hardware".
- Advanced 3D draws with Direct3D 11 (Calder.aex imports d3d11.dll and compiles its
  shaders with d3dcompiler_47), not Direct3D 12.
- A D3D11 API trace of a full run (apitrace) shows AE creating two D3D11 devices on
  the GPU at start and nothing after that: no textures, shaders or draws. The
  Advanced 3D renderer never starts drawing.
- Ruled out (tested one by one, still magenta):
  - `cuDeviceGetLuid` failing: fixed by patch 18. AE's own GPU tags then report the
    display and the CUDA device as the same adapter (with the DirectX display on).
  - DXVK reporting the GPU as AMD (`dxgi.hideNvidiaGpu` default):
    `DXVK_CONFIG="dxgi.hideNvidiaGpu = False"` makes AE see an NVIDIA adapter.
  - Direct3D 12 feature level 11_1 (dzn has no sparse resources, so vkd3d-proton
    stops at 11_1): `VKD3D_FEATURE_LEVEL=12_0` makes GPUSniffer report feature level
    12 (result 785 instead of 529).
  - AE's DirectX display on or off, project GPU mode CUDA or Mercury Software Only,
    and lavapipe instead of dzn.
- Not implemented in the CUDA bridge (nvidia-libs nvcuda): Direct3D interop.
  `cuGraphicsD3D11RegisterResource` returns CUDA_ERROR_NOT_SUPPORTED, and
  D3D11/D3D12 handle types are passed to the Linux libcuda unchanged. These
  functions were not called in the traced runs, so they are not shown to be the
  cause.
- Plugin recognition: AE's plugin scan does not recognise `Calder.aex` or `Ernst.aex`
  (the Cinema 4D renderer). A fresh scan logs "Loading from disk... No loaders
  recognized this plugin, so the plugin is set to Ignore." in the prefix's
  `Plugin Loading.log`. `Advanced3D.aex` (Classic 3D) and `Standard3D.aex` are
  recognised through AE's hardcoded PiPL list instead. `Calder.aex` has the same
  SHA-256 as the copy in the Windows AE 2024 install, and Wine loads it as a native
  module without import errors.
- The Ignore flag is not the failure by itself: the Windows AE 24.6 plugin cache also
  holds `Ignore=1` for `Calder` and `Ernst`. A fresh scan gave the same result with
  feature level 12_0, CUDA hidden, `dxgi.hideNvidiaGpu = False` and the DirectX
  display on. AE reports Windows 10 Pro, build 19045.
- In the traced runs no D3D11 work follows device creation (apitrace). Of the D3D
  interop calls, only `cuD3D11GetDevice` was logged (it returns device 0). A generic
  D3D11 test in the same prefix passes: `D3DCompile`, device creation at feature
  level 11_1 and 10_0, a draw and a readback.
- Not found: the code in AE that decides recognition and the on-demand load. The
  repository does not inspect Adobe binaries. The next useful step is a comparison
  with a working Windows run (its `Plugin Loading.log` and log during renderer
  selection); no AE 24.6 plugin log exists on the Windows side here. Untested: native
  Linux with NVIDIA's own Vulkan driver (no dzn; DXVK and vkd3d-proton reach feature
  level 12_x there). lavapipe gave the same magenta, so the cause is probably above
  the Vulkan driver.

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

- Native Linux hosts and distributions other than Ubuntu 24.04: the scripts detect
  them (no dzn, host Vulkan and GL drivers, distribution-specific install hints in
  doctor.sh), but nothing was run there.
