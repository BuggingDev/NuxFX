# Known issues

- **The red needle can stop during a 4K, 120 s RAM preview.** The picture and the sound are not
  affected; `tests/run_ae_ram_preview_heavy_test.sh` reports the needle without judging it.
- **After Effects 26: the Progress panel keeps "Initializing DeepLasso-20240605" and "Initializing
  UniversalRefinementModel-20240502" for ever.** Both come from the Object Mask models and are requested when After Effects
  starts. Roto Brush and Content-Aware Fill do not wait for them and work; what needs them (the Object Selection tool) is not tested.
- **After Effects 26 on a private Xvfb with Openbox (no compositing manager): after the first menu, later menus and
  drop-downs do not open and the panels ignore clicks** (the first menu leaves a black window behind). It happens with and
  without the files NuxFX adds, so it is not a side effect of the installer. Not checked on a desktop session. Panels can
  be opened without the mouse menu: `app.executeCommand(app.findMenuCommandId("Content-Aware Fill"))` in a script.

How each problem was found and fixed: [technical-note.md](technical-note.md).
