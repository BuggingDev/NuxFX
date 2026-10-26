# Contributing to NuxFX

By contributing you agree that your contribution is licensed under GPL-3.0-or-later
(see [LICENSE](LICENSE)).

## Patches for Mesa

- Base every patch on pristine Mesa 25.2.8. The tarball checksum is in
  `scripts/build_dzn.sh`.
- One logical change per patch. Number the patches in order and create them with
  `git format-patch`.
- Start the subject with the component, for example `dzn: implement ...`. Explain the
  problem and the fix in the body.
- Check that `scripts/build_dzn.sh` applies the whole series to a fresh Mesa tree.
- Mesa itself is MIT-licensed. See [NOTICE](NOTICE) for what that means for these patches.
- Users get dzn and the OpenGL driver as prebuilt packages (`prebuilt/manifest.txt`), tied to the patch
  series by its hash, so a changed patch needs new packages: build with `build_dzn.sh` and `build_gl.sh`
  in a fresh Mesa tree on the oldest supported system (Ubuntu 24.04), run `scripts/package_prebuilt.sh`,
  upload the assets it writes to a release with the tag it prints, and commit the new manifest. Until
  then the installer builds from source for that series.

## Scripts, tests and documentation

- Run `bash -n` on shell scripts before committing.
- Run `tests/run_gl_window_test.sh`, `tests/run_ae_viewer_test.sh`,
  `tests/run_ae_advanced3d_test.sh`, `tests/run_ae_advanced3d_scene_test.sh`,
  `tests/run_ae_advanced3d_size_test.sh`, `tests/run_ae_advanced3d_viewer_test.sh`,
  `tests/run_ae_effects_test.sh` and `tests/run_ae_ram_preview_test.sh` (and
  `tests/run_dxgi_present_test.sh`, `tests/run_push_descriptor_test.sh`,
  `tests/run_semaphore_share_test.sh` and `tests/run_d3d11_shared_texture_test.sh` for dzn
  changes, `tests/run_ae_wayland_test.sh` for changes to the display handling) where your setup
  allows it. [docs/tests.md](docs/tests.md) lists every test and what it needs.
- Do not commit Adobe files, logs with personal data or local paths.

## Reporting problems

Open an issue with the output of `scripts/doctor.sh`, the distribution and the GPU route (host
driver or Direct3D 12 / dzn), and the name of the AE log folder. Do not attach Adobe binaries.

## Repository layout

```
install.sh        one-command installer
patches/          26 patches (git format-patch) against pristine Mesa 25.2.8
prebuilt/         manifest.txt: the prebuilt Mesa packages (release assets) with SHA-256 and patch series hash
scripts/          build_dzn.sh          build and install dzn (Direct3D 12 route)
                  build_gl.sh           build and install Mesa's EGL and d3d12 OpenGL driver
                  fetch_prebuilt.sh     download and install the prebuilt dzn or OpenGL package
                  package_prebuilt.sh   package a source build as release assets and write the manifest
                  build_layer.sh        build the optional apiVersion layer
                  launch_ae.sh          start After Effects (applies ae_prefs.sh and clear_crash_state.sh)
                  stop_ae.sh            stop After Effects and its wineserver
                  doctor.sh             read-only check of host, prefix, After Effects and tools
                  ae_prefs.sh           the After Effects preferences this setup needs
                  clear_crash_state.sh  clears After Effects' previous-crash state
                  common.sh             shared settings, platform and display detection, audio plan, package hints
                  sound_keepalive.sh    silent stream that keeps the sound server's output awake (RAM preview)
                  null_audio.sh         optional silent PulseAudio server of its own (AEGNUX_NULL_AUDIO=1)
                  gpu_sniffer_test.sh   entrypoint audit, then GPUSniffer
                  dzn_audit.c, gen_cmds.py   entrypoint audit of dzn
                  apiver_layer/         optional Vulkan layer (apiVersion), off by default
                  tools/                xcap.c (X11 screen capture for the tests), silent_stream.py,
                                        memcpy_probe.c and pcsample.py (profiling aids)
tests/            run_*.sh and the C and GLSL sources they build
docs/             how-it-works.md, configuration.md, troubleshooting.md, wayland.md, tests.md,
                  known-issues.md, technical-note.md, manual-installation.md, screenshots/
```
