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
  `scripts/apiver_layer/` does the same from outside the driver. Both are kept on
  purpose; either alone is enough for AE.
- **KHR_external_memory_win32 and KHR_external_semaphore_win32** are turned off in
  `_WIN32` builds (patch 15). This is not exercised on Linux.

## Advanced 3D

- The plugin loads, the renderer can be selected, and a 3D layer can be created.
- **Rendered output has not been verified.** In our captures the viewer showed only
  the background, also for Classic 3D, so the capture method cannot prove or
  disprove rendering. The "Save Frame As" check did not complete.
- Frame render time in the status bar increased when Advanced 3D was active. This is
  an observation only.

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
- Development logs mention `dxgi: SetBackgroundColor: Not implemented`,
  `nvcuda LUID` warnings and Wine `fixme` lines. They were not investigated.

## Not included

- Adobe binaries, DLLs and logs. You need your own After Effects 2024 installation.
- The Wine runner and the aegnux prefix. Use aegnux or your own runner.
- The debugging instrumentation used to find the bugs (removed before the patches
  were produced).