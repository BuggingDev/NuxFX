# Technical note: After Effects 2024 under dzn (Dozen) in WSL2

Status date: 2026-10-18. Mesa 25.2.8 with the patches in `patches/`. Test host:
WSL2 Ubuntu 24.04, NVIDIA GeForce RTX 4060 Ti 8 GB, Wine TkG 11.12 runner,
After Effects 2024 (24.6.2.2), DXVK 3.0.1 as shipped with the aegnux prefix.

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
     allocated : _mesa_hash_table_create_u32_keys <- dzn_meta_blits_init <- dzn_meta_init
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
   The shader therefore read undefined data, the loop ran for a very large count,
   and the GPU timed out.

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
feature"). Those bits are advertised (patches 15 and 16). See known-issues.md for
what is not implemented behind `inlineUniformBlock` and `nullDescriptor`.

DXVK reads format features only through VkFormatProperties3 (core 1.3). Without
patch 14 every format reports zero features and render target creation fails.

## 5. Extensions and entrypoints added or completed

| Patch | Extensions / entrypoints | Implementation |
|---|---|---|
| 04 | apiVersion reported to the loader | Workaround, see known-issues |
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
| 15 | many feature bits | Mixed, see known-issues |
| 16 | shaderZeroInitializeWorkgroupMemory | Real: NIR pass |

## 6. Audit tool

`scripts/dzn_audit.c` checks every advertised device command with
`vkGetDeviceProcAddr`. It reports NULL entries and groups of non-alias commands that
share one pointer (how a stub group appears). It cannot identify a single
unimplemented command that resolves to the stub. Run `gpu_sniffer_test.sh` to
generate the list and run it.

## 7. Advanced 3D (partial)

Verified, using AE's own UI and logs:
- `Advanced3D.aex` is loaded at start ("Loading ... Advanced3D.aex", PiPL recognised).
- Composition Settings > 3D Renderer lists Classic 3D, Advanced 3D and Cinema 4D.
  Selecting Advanced 3D shows its description and feature lists with no error dialog.
- The viewer toolbar then shows the Advanced renderer; a solid can be turned into a
  3D layer (3D properties appear).

Not verified:
- Rendered output. The viewer region of AE's window looked empty in captures for
  both Classic 3D and Advanced 3D, so the capture method could not show pixels.
  "Save Frame As" was attempted but the output dialog did not reliably open. No
  pixel-level result exists.

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