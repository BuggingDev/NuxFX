# Known issues

- **Roto Brush propagation and Content-Aware Fill do not finish.** A Roto Brush stroke makes the matte
  of its frame, but propagating it to the other frames (which Content-Aware Fill needs too) stays at
  "initializing Adobe Sensei propagation module" and After Effects waits for it: the Direct3D 12
  device that DirectML runs on is lost (`VK_ERROR_DEVICE_LOST` from dzn). Warp Stabilizer works.
- **The red needle can stop during a 4K, 120 s RAM preview.** The picture and the sound are not
  affected; `tests/run_ae_ram_preview_heavy_test.sh` reports the needle without judging it.

How each problem was found and fixed: [technical-note.md](technical-note.md).
