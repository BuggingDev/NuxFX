# Known issues

Status: 2026-10-25, NuxFX with Wine TkG staging 11.12, DXVK 3.0.1, vkd3d-proton 3.0.1 and Mesa 25.2.8 with
the patches in `patches/`. How each problem was found and fixed: [technical-note.md](technical-note.md).

- **The red needle can stop in a very long 4K RAM preview.** In a 3840x2160, 120 s preview the
  red preview-time needle sometimes stops a few seconds after the start (2 of 5 runs of
  `tests/run_ae_ram_preview_heavy_test.sh`); picture and sound are not affected.
- **After Effects' DirectX display is off.** The CUDA bridge cannot share images with Direct3D, so
  `ae_prefs.sh` makes After Effects use its other display (`DS.DisableDirectXDisplay`); CUDA rendering
  stays on.
- **dzn lacks transform feedback (a stub that warns), inline uniform blocks and sparse resources.**
  After Effects, DXVK and vkd3d-proton do not use them.
- **Wine's own Wayland driver is not used.** After Effects runs through XWayland ([wayland.md](wayland.md)).
- **Not run:** a host with a native GPU driver, AMD and Intel GPUs, GNOME.
