# Known issues

- **The red needle can stop during a 4K, 120 s RAM preview.** The picture and the sound are not
  affected; `tests/run_ae_ram_preview_heavy_test.sh` reports the needle without judging it.
- **After Effects 26: what Adobe builds on `AdobePIE.dll` (the Photoshop imaging engine) does not work.** The Render Queue
  cannot write TIFF and Photoshop (PSD) files: the render stops with "The Photoshop Library operation failed because of a
  program error" (error code 14) and leaves a 0-byte file. The Vibrance effect renders a transparent frame (CUDA and software),
  and Brightness & Contrast does in software mode (CUDA mode works). H.264, AVI, AIFF and PNG sequences are written, TIFF and
  PSD files are imported, and the other tested effects render. The cause is in the engine: `PSLImage::GetLayer`
  is asked for layer 0 of an image it has just made and that has none. Tried without effect (26.5): Mercury Software Only,
  the DirectX and OpenGL display, a color managed project, Windows 11 as the reported version.
  `tests/run_ae_features_test.sh` leaves the TIFF step out for After Effects 26 and says so.
- **After Effects 26: Roto Brush propagation and Content-Aware Fill do not complete.** The Quick Selection tool (the Object
  Matte effect) makes the matte of the frame it is used on. After the playhead moves, the Composition and Layer panels keep the
  old picture, later frames do not render, and the banner "Object Matte initializing Adobe Sensei propagation module..." stays.
  In the Content-Aware Fill panel the Fill Target shows the hole of a Subtract mask, but "Generate Fill Layer" starts nothing.
  After Effects 24 does both (README). Not looked at yet: the ONNX Runtime and DirectML path under dzn that both use.

How each problem was found and fixed: [technical-note.md](technical-note.md).
