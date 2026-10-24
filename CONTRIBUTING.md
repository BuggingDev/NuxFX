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

## Scripts, tests and documentation

- Run `bash -n` on shell scripts before committing.
- Run `tests/run_gl_window_test.sh`, `tests/run_ae_viewer_test.sh` and
  `tests/run_ae_advanced3d_test.sh` (and `tests/run_dxgi_present_test.sh` for dzn changes)
  where your setup allows it.
- Do not commit Adobe files, logs with personal data or local paths.

## Reporting problems

Open an issue with the output of `scripts/doctor.sh`, the distribution and the GPU route (host
driver or Direct3D 12 / dzn), and the name of the AE log folder. Do not attach Adobe binaries.
