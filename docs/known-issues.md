# Known issues

- **After Effects does not return from Content-Aware Fill.** "Generate Fill Layer" writes the fill
  frames (a `Fills` folder next to the project; 15 frames took about a minute), but the window then
  stops answering: the panel stays at "Initializing FastMask2ImgEncoder" and a script sent to the
  session gets no reply for at least 10 minutes. Roto Brush, including its propagation, and Warp
  Stabilizer work.
- **The red needle can stop during a 4K, 120 s RAM preview.** The picture and the sound are not
  affected; `tests/run_ae_ram_preview_heavy_test.sh` reports the needle without judging it.

How each problem was found and fixed: [technical-note.md](technical-note.md).
