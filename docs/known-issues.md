# Known issues

- **Uncompressed 24-bit AVI (and MJPEG AVI) imports as black frames.** AVI with YUY2, UYVY or DV video,
  and H.264, HEVC, ProRes, DNxHD, MPEG-4, PNG-in-MOV, PSD, TIFF, TGA, DPX, EXR and the other still
  formats import correctly.
- **The red needle can stop in a 4K, 120 s RAM preview** (2 of 5 runs of
  `tests/run_ae_ram_preview_heavy_test.sh`); the picture and the sound are not affected.
- **After Effects' DirectX display is off**: the CUDA bridge cannot share images with Direct3D, so
  `ae_prefs.sh` makes After Effects use its other display; CUDA rendering stays on.

How each problem was found and fixed: [technical-note.md](technical-note.md).
