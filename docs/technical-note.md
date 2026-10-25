# Technical note: After Effects 2024 under dzn (Dozen) on the Direct3D 12 route

Status date: 2026-10-18. Mesa 25.2.8 with the patches in `patches/`. Test host:
Ubuntu 24.04 on the Direct3D 12 route (`/dev/dxg`), NVIDIA GeForce RTX 4060 Ti 8 GB, Wine TkG 11.12
runner, After Effects 2024 (24.6.2.2), DXVK 3.0.1 as shipped with the aegnux prefix.

## 1. Symptom

AE starts, loads its plugins (Advanced3D.aex is loaded), runs the GPUSniffer
test and creates DXVK devices. Within 20 to 30 seconds of start, after a
D3D12 device is torn down, the next `vkCreateDevice` crashes:

```
0024:err:vulkan:vkCreateDevice Exception 0xc0000005 in Unix call.
malloc(): unsorted double linked list corrupted
```

The faulting instruction was in Mesa's `ralloc.c` (`unsafe_free`), inside
`libvulkan_dzn.so`: a child list pointed at freed memory.

## 2. How it was narrowed down

1. Heap validation (patch 01). `RALLOC_DEBUG_VALIDATE` quarantines freed blocks and
   records call stacks. The first report of a failing run was:

   ```
   RALLOC-VIOLATION: ralloc_free of a freed block (double free) ... size=72
     violation : dzn_meta_blits_finish <- dzn_device_destroy <- dzn_device_create
     allocated : _mesa_hash_table_create_u32_keys <- dzn_meta_init (dzn_meta_blits_init inlined)
     freed     : dzn_meta_blits_finish <- dzn_meta_init (error path)
   ```

   A failing run gave four such reports (two per failed device creation, for the
   hash tables `meta->fs` and `meta->contexts`).

2. Why meta init failed. `ID3D12Device1::CreateComputePipelineState` returned
   `0x887a0005` (`DXGI_ERROR_DEVICE_REMOVED`) for the first indirect draw meta
   shader. `ID3D12Device::GetDeviceRemovedReason` returned `0x887a0006`
   (`DXGI_ERROR_DEVICE_HUNG`) at the same time. The device had been lost, so the
   failure was a consequence of a GPU hang, not of the meta code itself.

3. What hung the GPU. Device-removed probes at each submission showed that the
   state changed between two submissions. The last command buffer submitted before
   the change contained one `vkCmdDrawIndexed` (6 indices, 1 instance). Its fragment
   shader (SPIR-V module f54a66e3, vertex shader 34ebe8dc) contains loops whose trip
   count is read from a uniform block (`cb0_buf`, set 2, binding 1, member 4).
   Before the fix, the same draw had no descriptor sets bound at all. Logs showed
   zero `vkCmdBindDescriptorSets` calls, and every set pointer at the draw was NULL.
   An unbound constant buffer gives an arbitrary loop count. This is inferred from
   the shader; the count itself was not read back. The GPU then timed out.

4. Why no descriptors were bound. Mesa's common runtime implements
   `vkCmdBindDescriptorSets` by calling the driver's `vkCmdBindDescriptorSets2KHR`
   (VK_KHR_maintenance6). dzn advertised maintenance6 but did not implement
   `vkCmdBindDescriptorSets2KHR` or `vkCmdPushConstants2KHR`. A missing entrypoint
   resolves to the runtime's no-op stub, so DXVK's v2 calls did nothing. Patch 06
   implements both as wrappers over the v1 functions. After the change, the same run
   logged 202 bind calls and no device loss.

5. Experiments that did not change the outcome or were rejected:
   - Disabling VK_KHR_push_descriptor did not avoid the hang (the push path is not the cause).
   - Disabling the maintenance6 advertisement stopped device creation altogether, so
     it is not a fix.
   - Skipping the one hanging command buffer (a development-only hook, not in the
     patches) avoided the hang and the crash. This confirmed that the hang leads
     to the crash, and that the crash path is the meta error path.
   - Other causes were ruled out before this analysis (a glsl refcount change alone,
     removing the zero-init pass, MALLOC_CHECK_, an LD_PRELOAD malloc guard, gdb
     breakpoints). They are not repeated here.

## 3. Fixes in the series

| Patch | Change | Why |
|---|---|---|
| 02 | Meta objects released exactly once | Double free on device creation failure |
| 03 | glsl singletons referenced for device lifetime | Meta blit NIR is compiled while recording commands |
| 06 | `vkCmdBindDescriptorSets2KHR`, `vkCmdPushConstants2KHR` | Silently dropped descriptor and push constant updates; the GPU hang |
| 16 | Workgroup memory zero-initialization | DXVK 3.x requires `shaderZeroInitializeWorkgroupMemory` |

Result with the full series and heap validation off, 150 s runs, `rc 124` (AE still
running at the timeout):

```
creating device: 4 or 5     (DXVK "Creating device" lines)
exception 0xc0000005: 0
malloc corruption: 0
device removed: 0
```

A device-creation failure test (a temporary hook forcing `dzn_meta_init` to fail,
removed afterwards) reported four double frees before patch 02 and none after it.

## 4. GPUSniffer checks

GPUSniffer.exe (AE Support Files) gates the Advanced 3D and GPU paths. Its DirectX
test failed on these items, now fixed by the series (result 529, pass):

- VK_EXT_transform_feedback missing (patch 09, stub only)
- VK_EXT_texel_buffer_alignment, single texel alignment (patch 10)
- VK_KHR_push_descriptor missing (patch 07)
- queue families with minImageTransferGranularity 0 are skipped by vkd3d-proton (patch 13)

DXVK 3.0.1 also refuses an adapter that lacks `inlineUniformBlock`, `nullDescriptor`
or `shaderZeroInitializeWorkgroupMemory` (log line "Device does not support required
feature"). Those bits are advertised (patches 15 and 16). `nullDescriptor` works;
`inlineUniformBlock` is advertised but not implemented (DXVK and vkd3d-proton never allocate one).

DXVK reads format features only through VkFormatProperties3 (core 1.3). Without
patch 14 every format reports zero features and render target creation fails.

## 5. Extensions and entrypoints added or completed

| Patch | Extensions / entrypoints | Implementation |
|---|---|---|
| 04 | apiVersion reported to the loader | Workaround, see the patch |
| 05 | VK_KHR_maintenance4, VK_KHR_maintenance5 | Real: memory requirements by create-info, subresource layouts, index buffer size |
| 06 | VK_KHR_maintenance6 | Real: v2 bind and push constant wrappers |
| 07 | VK_KHR_push_descriptor | Real: per-command-buffer descriptor pools |
| 08 | push constants up to 256 bytes | Real: root CBV upload |
| 09 | VK_EXT_transform_feedback | STUB: entrypoints exist and do nothing |
| 10 | VK_EXT_texel_buffer_alignment | Real (alignment reported) |
| 11 | VK_EXT_depth_clip_enable | Real for the pipeline state |
| 12 | VK_KHR_vulkan_memory_model | SPIR-V memory model accepted |
| 13 | minImageTransferGranularity | Reporting change |
| 14 | VkFormatProperties3 | Mirrors legacy masks |
| 15 | many feature bits | Mixed, see the patch (inline uniform blocks are not implemented) |
| 16 | shaderZeroInitializeWorkgroupMemory | Real: NIR pass |

## 6. Audit tool

`scripts/dzn_audit.c` checks every advertised device command with
`vkGetDeviceProcAddr`. It reports NULL entries and groups of non-alias commands that
share one pointer (how a stub group appears). It cannot identify a single
unimplemented command that resolves to the stub. Run `gpu_sniffer_test.sh` to
generate the list and run it. The list that `scripts/gen_cmds.py` makes puts
`vkCmdWriteBufferMarker2AMD` and `vkGetQueueCheckpointData2NV` under
`VK_KHR_synchronization2`; they come from AMD and NV extensions that dzn does not
advertise, so they show as NULL and are expected.

## 7. Advanced 3D

Correction: `Advanced3D.aex` (match name `ADBE Advanced 3d`) is the Classic 3D
renderer. The AE 24 Advanced 3D renderer is `Calder.aex` (`ADBE Calder`). The notes
that were here described Classic 3D. Current state: sections 11 and 12.

## 8. Debugging method used (not in the patches)

- Device removed probes at device creation and at each submission.
- Per-command logs: bind, draw, dispatch, copy, pipeline module hashes, plus
  per-process ids (several Wine processes write to one `err.log`).
- SPIR-V dumps of the hanging pipeline modules, disassembled with spirv-dis.
- A development-only command buffer skip hook used to confirm the cause.

All of this instrumentation was removed before the patch series was produced.

## 9. Operational notes

- A Wine server that is not stopped keeps rewriting `user.reg`. The stop script must
  set `WINEPREFIX` for `wineserver -k`, or the crash-state edits are undone.
- AE shows "Crash Repair Options" when the previous session stayed in AppState
  0x3e8 or when `AE.DebugShowPreviousCrashWarning` is true. `clear_crash_state.sh`
  handles both.
- `Creating device` lines come from DXVK, not from dzn.
## 10. Black D3D11 windows and the empty Composition panel

Two separate problems looked like one ("the panel does not draw"):

1. **dzn ignored the count-variant viewport/scissor dynamic states (patch 17).**
   DXVK's present blit uses VK_DYNAMIC_STATE_VIEWPORT_WITH_COUNT and
   vkCmdSetViewportWithCount. dzn treated such pipelines as static and never saw the
   runtime's dynamic viewport, so the blit drew nothing and every D3D11 swapchain
   window was black. Narrowed down with a Vulkan replica of DXVK's present: the
   replica stayed correct while matching shaders, specialization constants, push
   constants, descriptor heaps, update templates, blending, topology, image count and
   swapchain size one by one; switching to the WITH_COUNT dynamic states alone turned
   it black.
2. **AE's DirectX display needs CUDA and Direct3D 12 to share images.** After patch 17
   D3D11 windows were correct, but the Composition panel still stayed empty. AE created
   vkd3d-proton swapchains for its panels and never presented to them; the same
   happened on lavapipe, so it was not a driver bug. Hiding CUDA from AE, or keeping
   CUDA and setting `DS.DisableDirectXDisplay`, made the panel render. The CUDA bridge
   in the prefix cannot share resources with vkd3d-proton (`cuDeviceGetLuid` fails),
   so the DirectX display path never completes. `scripts/ae_prefs.sh` applies the
   setting before each start; `tests/run_ae_viewer_test.sh` checks the result.

Tools that made this tractable: tracing Wine's Vulkan thunks (+vulkan) to count
submits, acquires and presents per run; an A/B run on lavapipe; and running AE on a
private Xvfb display, because input on the desktop window and first-run tips changed
test results.

## 11. Advanced 3D (October 2026)

Method: a temporary startup script creates a comp with a red 3D solid rotated 40
degrees, sets the renderer and renders one frame through the render queue to a TIFF,
so the result does not depend on the Composition panel. Classic 3D gives the
expected rotated solid. Advanced 3D (`ADBE Calder`) gives a solid magenta frame.

1. Advanced 3D uses Direct3D 11 through DXVK, not Direct3D 12.
2. A D3D11 trace (apitrace's wrappers plus small forwarding DLLs for
   `D3D11CoreCreateDevice`, `D3D11On12CreateDevice` and
   `DXGIDeclareAdapterRemovalSupport`, which the wrappers do not export and DXVK's
   d3d10core needs) shows two D3D11 devices created at start and no D3D11 work after
   that.
3. AE's crash-reporter tags (written to the prefix's Temp folder) show how AE sees
   the GPUs: with the DirectX display off, "gpu-display OpenGL(AMD)" and
   "gpu-different-adapter true"; with the DirectX display on and DXGI reporting
   NVIDIA, "DirectX(NVIDIA)" and "false". Advanced 3D stayed magenta in both.
4. `cuDeviceGetLuid` failed because dzn's device UUID did not match the CUDA UUID;
   patch 18 fixes that. Forcing Direct3D 12 feature level 12_0, unhiding the NVIDIA
   vendor ID in DXGI, the display mode, the project GPU mode and lavapipe did not
   change the result.

## 12. Crash in the Advanced 3D viewer (October 2026)

Symptom: with a 1920x1080 Advanced 3D comp in the Composition panel, a click on the Draft 3D button
ended in "After Effects error: Crash in progress. Last logged message was: <828> <3D.Tiling> <5>
Tile size Y: 689" a few seconds later. The same comp rendered with `saveFrameToPng` never crashed.
The Wine log (`err+seh` on) had no exception line, the kernel log no OOM kill, and DXVK logged no
error. It reproduced on every click, with the stock driver and with the series up to patch 20.

1. The crash box is AE's own. Its crash reporter (Sentry breadcrumbs and event tags in
   `AppData/Local/Temp/Adobe/After Effects/24.0/SentryIO-db`) records the box on the display thread
   with a two-frame stack (`AfterFXLib.dll` and `kernelbase.dll`: the unhandled-exception filter).
   The event tags (`gpu-mem-overcommitted false`, `PanicSave true`) rule out a memory limit.
2. The process was still alive behind the box. `winedbg --command "info proc"` gave its pid;
   a script with `attach 0x<pid>`, `bt all` and `detach` printed the stack of every thread (the PE
   frames are unwound from the unwind tables, so no Adobe disassembly is involved). The thread that
   showed the box went: `ntdll` exception dispatch, `kernelbase` `RaiseException`, then four frames
   in `d3d11.dll`, then `videoframe.dll`, `AfterFXLib.dll`, `aedisplay.dll`. `d3d11.dll` is DXVK 3.0.1.
3. The frames of `d3d11.dll` were identified with `objdump -d -M intel` on the DLL (image base from
   `objdump -x`, return addresses from the stack, strings at rip-relative operands read from `.rdata`).
   The innermost frame loads `0x20474343` (the code of a MinGW C++ throw) and calls `RaiseException`,
   the next is `__cxa_throw`, the third allocates a 32-byte exception object, builds it from the string
   "Failed to import timeline semaphore" and throws it. Source of DXVK v3.0.1: that string is in
   `DxvkFence::DxvkFence` (`dxvk_fence.cpp`), reached from `D3D11Device::OpenSharedResource1`
   (`d3d11_device.cpp`), which creates the fence of a keyed mutex outside of its `try` block. AE's
   frames are MSVC code and do not catch a GCC exception, so the unhandled-exception filter ran.
4. Why the import fails. Wine's trace channels `+d3dkmt,+vulkan,+server` show, for the same call
   sequence in a 100-line D3D11 program (`tests/d3d11_shared_texture_test.c`), that Wine's `win32u`
   finds the shared object, gets a file descriptor for it (`get_handle_fd` succeeds) and then calls the
   host driver's `vkImportSemaphoreFdKHR`, which returns an error. A native Vulkan program
   (`tests/semaphore_share_test.c`) shows the same without Wine: export works, import returns
   `VK_ERROR_INVALID_EXTERNAL_HANDLE`, for a duplicate of the fd, for the fd itself and on the same
   device. A debug print in `dzn_sync_import_opaque_fd` showed `OpenSharedHandle` returning
   0x80070057 (E_INVALIDARG).
5. A raw Direct3D 12 program (the route's `libd3d12.so` and `libdxcore.so` through `dlopen`, DirectX-Headers)
   made the limit visible:

   | Object | CreateSharedHandle | OpenSharedHandle on another device |
   |---|---|---|
   | fence, `D3D12_FENCE_FLAG_SHARED` | ok | E_INVALIDARG (also on the same device, with a duplicate of the handle, with `SHARED_CROSS_ADAPTER`, as `ID3D12Fence1`) |
   | fence, `OpenSharedHandleByName` | ok | E_NOTIMPL |
   | committed texture, `D3D12_HEAP_FLAG_SHARED` | ok | ok |
   | heap, `D3D12_HEAP_FLAG_SHARED` | ok | ok |

   A native Vulkan program that exports the memory of an image on one device and imports it on another
   reads the pixels back correctly (also with `oldLayout` UNDEFINED), so dzn's memory sharing is fine.
6. What was rejected: dzn without `VK_KHR_external_semaphore_fd` and without `import_opaque_fd` and
   `export_opaque_fd` in its sync type: DXVK logs "Exporting semaphores of type 2 not supported by
   device" and then dies with "page fault on execute access to 0" in the keyed mutex path (a null
   function pointer). An import that succeeds without sharing would let the first `AcquireSync` wait
   forever, because it waits (without a timeout) for a fence value that the other device never
   signals. A DXVK 3.0.1 rebuilt with a `try`/`catch` around `createFence` returns E_FAIL from
   `OpenSharedResource1` and AE survives the click.
7. Fix (patch 21): the value of an exported or imported timeline semaphore lives in a memfd page, as
   described in the commit message of patch 21. DXVK only needs CPU signals and CPU waits for a keyed
   mutex. Patch 26 later made a CPU signal visible at once (a race in the export).

Result on the same machine and driver otherwise unchanged:

| Test | Without patch 21 | With patch 21 |
|---|---|---|
| `tests/run_semaphore_share_test.sh` | import returns -1000072003, FAIL | 17 checks pass |
| `tests/run_d3d11_shared_texture_test.sh`, plain | pass | pass |
| `tests/run_d3d11_shared_texture_test.sh`, keyed mutex | `terminate called after throwing an instance of 'dxvk::DxvkError'` | the second device reads (255, 128, 64, 255) |
| `tests/run_ae_advanced3d_viewer_test.sh` | error box after the first click | no box, the 3D text is on screen after both clicks |

Side findings of the same work:

- `CompItem.draft3d` and `app.executeCommand` do not take the path of the Draft 3D button (the
  menu command id is not found), so a script cannot reproduce the crash; the viewer test clicks.
- A first demo scene rendered as a dark gradient. The cause was the scene, not the renderer: a spot
  light aimed away from the text and `Casts Shadows` = 2 on the text. On the `Casts Shadows` menu of a
  layer, 2 is "Only": the layer is not drawn, only its shadow (1 and 3 draw it and cast). The shadow
  scene of `run_ae_advanced3d_scene_test.sh` used 2 and never drew its text; it uses 1 now.
- An earlier note said that shared D3D11 textures were not coherent between two devices. The test
  cleared the texture with `ClearRenderTargetView`, which DXVK keeps back until the image is used on
  the same device. With `UpdateSubresource`, a draw or a copy the second device reads the data.
