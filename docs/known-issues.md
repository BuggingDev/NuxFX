# Known issues

- **The red needle can stop during a 4K, 120 s RAM preview.** The picture and the sound are not
  affected; `tests/run_ae_ram_preview_heavy_test.sh` reports the needle without judging it.
- **After Effects 26: Roto Brush propagation and Content-Aware Fill do not complete.** The Quick Selection tool (the Object
  Matte effect) makes the matte of the frame it is used on. After the playhead moves, the Composition and Layer panels keep the
  old picture, later frames do not render, and the banner "Object Matte initializing Adobe Sensei propagation module..." stays.
  In the Content-Aware Fill panel the Fill Target shows the hole of a Subtract mask, but "Generate Fill Layer" starts nothing.
  After Effects 24 does both (README). Not looked at yet: the ONNX Runtime and DirectML path under dzn that both use.

How each problem was found and fixed: [technical-note.md](technical-note.md).
