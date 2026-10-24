# Tests

Every test is a script in `tests/` (`run_*.sh`) with the C and GLSL sources it builds. They print
`PASS` or `FAIL` and exit with 0 or 1. Run them from the repository root:

```sh
tests/run_gl_window_test.sh        # an OpenGL child window reaches the screen (no After Effects needed)
tests/run_ae_viewer_test.sh        # the Composition panel shows a rendered comp
tests/run_ae_wayland_test.sh       # the same, on a Wayland compositor (sway, headless) with XWayland
tests/run_ae_advanced3d_test.sh    # Advanced 3D renders a tilted 3D solid; the project uses CUDA
tests/run_ae_advanced3d_scene_test.sh  # cameras, lights, shadows, Environment-light IBL, text and stress
tests/run_ae_advanced3d_size_test.sh   # Advanced 3D frames from 480x270 to 1920x1080
tests/run_ae_advanced3d_viewer_test.sh # a 1080p Advanced 3D scene in the Composition panel; Draft 3D clicked twice (patch 21)
tests/run_ae_ram_preview_test.sh   # RAM preview plays a 10 s comp at about real time
tests/run_ae_effects_test.sh       # 40 common effects render in CUDA and in software mode
tests/run_push_descriptor_test.sh  # dzn push descriptors reach a compute shader (patch 20)
tests/run_descriptor_features_test.sh  # null descriptors and inline uniform blocks on the Vulkan device
tests/run_semaphore_share_test.sh  # two Vulkan devices share a timeline semaphore (patch 21)
tests/run_d3d11_shared_texture_test.sh  # two Direct3D 11 devices share a texture, with and without a keyed mutex (patch 21)
tests/run_dxgi_present_test.sh     # a Direct3D 11 swapchain shows its backbuffer (patch 17)
scripts/gpu_sniffer_test.sh        # dzn entrypoint audit, then After Effects' GPUSniffer test
```

## What they need

- The OpenGL window test and the After Effects tests run on a private display, so nothing appears
  on your desktop and no input can interfere: a private Xvfb server, or for the Wayland test a
  private sway compositor. (`run_dxgi_present_test.sh` and `gpu_sniffer_test.sh` open their windows
  on your current display.)
- Packages: `xdotool`, `xwininfo` (`x11-utils`), `xvfb`, `python3` and `gcc` with X11 headers; the
  Windows test programs need `x86_64-w64-mingw32-gcc`; the Wayland test needs `sway`, `grim` and
  `Xwayland`. `scripts/doctor.sh` prints the install command for your distribution.
- `run_push_descriptor_test.sh` and `run_descriptor_features_test.sh` need the Vulkan headers and
  loader (`libvulkan-dev`), `glslangValidator` and the dzn build. `gpu_sniffer_test.sh` needs the dzn
  build and the After Effects files.
- The After Effects tests stop any After Effects of the prefix that is running.

## What each test checks

- `run_gl_window_test.sh` opens a Windows window with an OpenGL child window (how After Effects
  draws the Composition panel) and looks for its cyan fill in a screenshot. It fails and names the
  missing library when Wine cannot show the child window. About 15 seconds.
- `run_ae_viewer_test.sh` starts After Effects with a temporary startup script that creates a comp
  with a red solid and an Invert effect, and passes if the panel shows cyan.
- `run_ae_wayland_test.sh` does the same inside a private sway compositor (headless backend, XWayland
  on, its own sockets), started so that `WAYLAND_DISPLAY` and `DISPLAY` are both set, as in a Wayland
  desktop session, and takes the screenshot with `grim`. It also prints which Wine display driver
  After Effects loaded. With `AEGNUX_WAYLAND=1` it runs Wine's own Wayland driver instead of X11
  through XWayland. About 3 minutes.
- `run_ae_advanced3d_test.sh` selects the Advanced 3D renderer for a comp with a tilted red 3D
  solid, saves frame 0 as a PNG and passes if the renderer stays `ADBE Calder`, the project uses
  CUDA and the PNG shows red and no magenta. The result travels in the name of a comp in a project
  the script saves, because After Effects scripts may not write files by default.
- `run_ae_advanced3d_scene_test.sh` starts After Effects once and builds six small comps: a moving
  camera, a point light, an Environment light that casts shadows, extruded 3D text against Classic
  3D, an Environment light that lights a wall and text, and a 30-solid stress scene. Each frame
  must be valid (no magenta, not one colour) and each feature must change the picture in the
  expected direction. `AEGNUX_A3D_SCENES=cam,light,...` runs a subset. About 4 minutes.
- `run_ae_advanced3d_size_test.sh` builds one scene (extruded text, a wall, a camera, a point light;
  and a variant with an Environment light that casts shadows) at 480x270, 960x540, 1280x720 and
  1920x1080, renders frame 0 of each to a PNG and checks that the picture is valid and shows the
  text. About 2 minutes. `AEGNUX_A3D_SIZES=1920x1080` runs one size.
- `run_ae_advanced3d_viewer_test.sh` shows a 1920x1080 Advanced 3D comp in the Composition panel
  and clicks the Draft 3D button of the viewer twice (a script cannot take the path that the button
  takes). It passes when After Effects is still running, no error box appeared and the orange 3D
  text is on screen before and after. Before patch 21 the first click ended with "Crash in
  progress". About 4 minutes.
- `run_semaphore_share_test.sh` (no Wine, no After Effects) lets two Vulkan devices share a
  timeline semaphore as an opaque fd: CPU signals, queue signals and queue waits must cross, and
  an imported semaphore must be exportable again. It skips when the device has no external
  semaphore fd support. `run_d3d11_shared_texture_test.sh` does the same one level up: two
  Direct3D 11 devices share a texture with and without a keyed mutex, and the second device must
  read the pixel the first one wrote.
- `run_ae_ram_preview_test.sh` builds a 10 s comp with a moving, rotating layer, presses space in
  the Composition panel and follows the picture in screenshots (the position of the layer is the
  comp time on screen). It prints the playback speed and passes at 0.8 times real time or more.
  The playhead of the timeline does not move during a preview (see the limitations in the
  README). About 3 minutes.
- `run_ae_effects_test.sh` applies 40 common effects (blur, glow, colour, noise, distort, stylize
  and transform effects), each with one non-default parameter, renders frame 0 of each in CUDA
  mode and again in software mode, and compares both with a comp without the effect. It passes
  when every applied effect renders in both modes; the table shows which effects change the
  picture and how far the two modes differ. About 8 minutes.
- `run_push_descriptor_test.sh` checks that push descriptors reach a compute shader.
  `run_descriptor_features_test.sh` checks which descriptor features the Vulkan device supports:
  null descriptors work, inline uniform blocks do not (see `docs/known-issues.md`).
