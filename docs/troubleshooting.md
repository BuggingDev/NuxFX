# Troubleshooting After Effects on Linux

Start with `scripts/doctor.sh`. It is read-only and prints what is missing, with the install command
for your distribution. When you report a problem, attach its output.

| Symptom | Cause and fix |
|---|---|
| The Composition panel is black although the timeline and the panels work | Wine opens `libXcomposite.so.1` at run time; without it OpenGL child windows stay black and nothing complains. Install it (`doctor.sh` prints the command). `tests/run_gl_window_test.sh` shows the effect |
| After Effects crashes, or Wine reports that it is out of memory, when memory use is high | Likely cause: the kernel limit on memory mappings per process (`vm.max_map_count`). Some distributions still ship the old default of 65530, and a program with a large working set needs far more. `doctor.sh` warns when it is below 1048576, and the installer raises it. By hand: `echo 'vm.max_map_count=1048576' \| sudo tee /etc/sysctl.d/99-nuxfx.conf && sudo sysctl --system`. A crash with the limit raised is a different problem: please report it with the `doctor.sh` output |
| No window appears in a Wayland session | After Effects needs XWayland (the tested setup). Install `xwayland`, log in again, and run `doctor.sh`; it shows the display setup and the Wine driver in use. See [wayland.md](wayland.md) |
| The Composition panel is empty on Arch Linux, Fedora 44 or Tumbleweed (Direct3D 12 route) | The distribution's Mesa 26 does not work with After Effects' viewer. `scripts/build_gl.sh` builds the tested Mesa 25.2.8 OpenGL stack (the installer does it); `AEGNUX_SYSTEM_GL` must not be `1` |
| "Advanced 3D is not supported by the current hardware" | After Effects needs CUDA and its accelerated display. Check that `AEGNUX_DISABLE_CUDA` is not set and that `doctor.sh` reports CUDA. Do not switch off After Effects' accelerated display or hide OpenGL from Wine |
| Advanced 3D frames are magenta after an earlier failed render | A stale disk cache serves the old frame. Empty it once (Preferences > Media & Disk Cache > Empty Disk Cache) |
| "Crash in progress. Last logged message was: <3D.Tiling> ..." when an Advanced 3D comp is in the Composition panel (Direct3D 12 route) | The dzn build lacks patch 21 (shared timeline semaphores); DXVK then throws out of `OpenSharedResource1`. Run `scripts/build_dzn.sh` again; `doctor.sh` warns about an old build. `tests/run_d3d11_shared_texture_test.sh` shows it without After Effects |
| "System Compatibility Report: Unsupported Video Driver" on every start (Direct3D 12 route) | Wine reported a second GPU. The scripts set `MESA_LOADER_DRIVER_OVERRIDE=d3d12`, which prevents it. If it shows anyway, click "Continue with known issues" |
| RAM preview plays at a fifth of real time (about 7 frames a second) on the Direct3D 12 route | glibc's `memcpy` uses `rep movsb`, which is very slow on the shared buffers of Mesa's d3d12 driver. The scripts set `GLIBC_TUNABLES=glibc.cpu.x86_rep_movsb_threshold=0x40000000`; `AEGNUX_REP_MOVSB` must not be `1`, and After Effects must be started through `scripts/launch_ae.sh` (or `aegnux_env`) |
| The first start shows nothing but an empty Home screen | `ae_prefs.sh` switches the Home screen off; run `scripts/launch_ae.sh` instead of `AfterFX.exe` directly |

More causes, evidence and the history of each fix: [known-issues.md](known-issues.md).
