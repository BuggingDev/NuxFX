# Known issues

- **The red needle can stop in a 4K, 120 s RAM preview** (2 of 5 runs of
  `tests/run_ae_ram_preview_heavy_test.sh`); the picture and the sound are not affected.
- **After Effects' DirectX display is off**: the CUDA bridge cannot share images with Direct3D, so
  `ae_prefs.sh` makes After Effects use its other display; CUDA rendering stays on.

How each problem was found and fixed: [technical-note.md](technical-note.md).
