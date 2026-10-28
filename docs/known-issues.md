# Known issues

- **The red needle can stop during a 4K, 120 s RAM preview.** The picture and the sound are not
  affected; `tests/run_ae_ram_preview_heavy_test.sh` reports the needle without judging it.
- **After Effects 26: the Render Queue cannot write TIFF and Photoshop (PSD) files.** The render stops with "The Photoshop
  Library operation failed because of a program error" (error code 14) and leaves a 0-byte file. H.264, AVI, AIFF and PNG
  sequences are written, and TIFF and PSD files are imported. The error is thrown inside `AdobePIE.dll`: `PSLImage::GetLayer`
  is asked for layer 0 of an image that has none. Tried without effect (26.5): Mercury Software Only, the DirectX and OpenGL
  display, a color managed project, Windows 11 as the reported version. `tests/run_ae_features_test.sh` leaves the TIFF step out
  for After Effects 26 and says so.

How each problem was found and fixed: [technical-note.md](technical-note.md).
