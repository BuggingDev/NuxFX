# Tests

Every test is a script in `tests/` (`run_*.sh`) with the C and GLSL sources it builds. They print
`PASS` or `FAIL` and exit with 0 or 1. Run them from the repository root:

```sh
tests/run_gl_window_test.sh        # an OpenGL child window reaches the screen (no After Effects needed)
tests/run_ae_viewer_test.sh        # the Composition panel shows a rendered comp
tests/run_ae_wayland_test.sh       # the same, on a Wayland compositor (sway, headless) with XWayland
AEGNUX_TEST_COMPOSITOR=kwin tests/run_ae_wayland_test.sh   # ... on KDE Plasma's KWin
tests/run_ae_advanced3d_test.sh    # Advanced 3D renders a tilted 3D solid; the project uses CUDA
tests/run_ae_advanced3d_scene_test.sh  # cameras, lights, shadows, Environment-light IBL, text and stress
tests/run_ae_advanced3d_size_test.sh   # Advanced 3D frames from 480x270 to 1920x1080
tests/run_ae_advanced3d_viewer_test.sh # a 1080p Advanced 3D scene in the Composition panel; Draft 3D clicked twice (patch 21)
tests/run_ae_ram_preview_test.sh   # RAM preview plays a 10 s comp at about real time; the red preview needle follows the picture
tests/run_ae_ram_preview_cached_test.sh # the classic RAM preview: renders the range into RAM first, then plays it in real time
tests/run_ae_ram_preview_cycles_test.sh # RAM preview starts and stops three times in one session (with the audio output launch_ae.sh gives)
tests/run_ae_ram_preview_heavy_test.sh  # a 4K, 120 s comp fills the RAM cache; After Effects stays up, memory is logged (needs ~12 GB free)
tests/run_pulse_resume_test.sh     # the sound server resumes a stream created corked after its output suspended (no Wine, no After Effects)
tests/run_ae_text_test.sh          # a new text layer gets a font with letters (Myriad Pro, After Effects' default)
tests/run_ae_effects_test.sh       # 40 common effects render in CUDA and in software mode
tests/run_push_descriptor_test.sh  # dzn push descriptors reach a compute shader (patch 20)
tests/run_descriptor_features_test.sh  # null buffer descriptors and inline uniform blocks on the Vulkan device
tests/run_robustness_test.sh       # out-of-range buffer and image accesses, null images and texel buffers (patch 22)
tests/run_xfb_stub_test.sh         # dzn warns once that transform feedback is not implemented (patch 23)
tests/run_d3d11_tessellation_test.sh   # a D3D11 hull/domain shader draws through DXVK for factors 1, 8, 64 (patches 24 and 25)
tests/run_semaphore_share_test.sh  # two Vulkan devices share a timeline semaphore (patch 21)
tests/run_d3d11_shared_texture_test.sh  # two Direct3D 11 devices share a texture, with and without a keyed mutex (patch 21)
tests/run_dxgi_present_test.sh     # a Direct3D 11 swapchain shows its backbuffer (patch 17)
scripts/gpu_sniffer_test.sh        # dzn entrypoint audit, then After Effects' GPUSniffer test
```

## What they need

- The OpenGL window test and the After Effects tests run on a private display, so nothing appears
  on your desktop and no input can interfere: a private Xvfb server, or for the Wayland test a
  private sway or KWin compositor. (`run_dxgi_present_test.sh` and `gpu_sniffer_test.sh` open their
  windows on your current display.)
- Packages: `xdotool`, `xwininfo` (`x11-utils`), `xvfb`, `python3` and `gcc` with X11 headers; the
  Windows test programs need `x86_64-w64-mingw32-gcc`; the tests that build a native Vulkan program
  (push descriptors, descriptor features, robustness, transform feedback, semaphores, GPUSniffer) need the
  Vulkan headers (`libvulkan-dev`) and `glslangValidator`; the Wayland test needs `Xwayland` and, for
  sway, `sway` and `grim`, for KWin `kwin_wayland`, `dbus-run-session`, `spectacle` and ImageMagick.
  `scripts/doctor.sh` prints the install command for your distribution.
- `run_push_descriptor_test.sh`, `run_descriptor_features_test.sh`, `run_robustness_test.sh` and
  `run_xfb_stub_test.sh` need the Vulkan headers and loader (`libvulkan-dev`), `glslangValidator`
  (not the last one) and the dzn build. `gpu_sniffer_test.sh` needs the dzn build and the After
  Effects files.
- The After Effects tests, `run_d3d11_shared_texture_test.sh` and `run_d3d11_tessellation_test.sh`
  use the Wine prefix and stop its Wine server when they finish: do not run them at the same time.

## What each test checks

- `run_gl_window_test.sh` opens a Windows window with an OpenGL child window (how After Effects
  draws the Composition panel) and looks for its cyan fill in a screenshot. It fails and names the
  missing library when Wine cannot show the child window. About 15 seconds.
- `run_ae_viewer_test.sh` starts After Effects with a temporary startup script that creates a comp
  with a red solid and an Invert effect, and passes if the panel shows cyan.
- `run_ae_wayland_test.sh` does the same inside a private compositor with XWayland and its own
  sockets, started so that `WAYLAND_DISPLAY` and `DISPLAY` are both set, as in a Wayland desktop
  session. The default is sway with the headless backend (screenshot with `grim`);
  `AEGNUX_TEST_COMPOSITOR=kwin` uses KDE Plasma's KWin with the virtual backend and its own D-Bus
  session (screenshot with Spectacle). It also prints which Wine display driver After Effects
  loaded. With `AEGNUX_WAYLAND=1` it runs Wine's own Wayland driver instead of X11 through XWayland.
  About 3 minutes.
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
  comp time on screen). It prints the playback speed (the better of the first pass and a repeat from
  the cache: the screenshots come at uneven intervals) and passes at 0.8 times real time or more. It
  also follows the timeline: during a preview After Effects keeps the blue playhead at the start
  and a red needle runs along the ruler; the test passes if the needle covers the comp and is on
  average less than 0.6 s from the picture (0.03 to 0.06 s in the runs). It also fails (exit status
  6) when After Effects ends during the run, which is how a crash shows. `AEGNUX_RP_COMP=WxHxS`
  changes the comp (the knobs are listed at the top of the script). About 3 minutes.
  `run_ae_ram_preview_cached_test.sh` is the same test for the classic RAM preview: with
  `AEGNUX_RP_CACHE_FIRST=1` it switches "Cache Before Playback" on for the Space shortcut (the
  numpad-0 key cannot be sent on a bare Xvfb display: no NumLock) and puts it back afterwards, so
  After Effects renders the whole range into RAM first and then plays it from the cache with its
  audio. `run_ae_ram_preview_heavy_test.sh` previews a 3840x2160, 120 s comp for four minutes so the
  RAM cache grows to After Effects' limit, logs the memory of After Effects and Wine every two
  seconds (`mem.txt` in `AEGNUX_TEST_LOGDIR`), stops After Effects if the machine drops below
  `AEGNUX_RP_MIN_AVAILABLE_MB` (default 2500) and reports the peak. It needs about 12 GB of available
  memory (it skips below that) and takes about 7 minutes.
  `run_ae_ram_preview_cycles_test.sh` (the same script with `AEGNUX_RP_CYCLES=3`) starts and stops
  the preview three times in one session: a cycle passes if the preview starts and, after the key
  that stops it, the needle is gone and the blue playhead has moved to the stop frame. The sound
  server of the Direct3D 12 route's display stack breaks this unless a silent stream keeps its
  output awake: the first stop takes a second longer and the next preview does not start (see
  `docs/known-issues.md`). Both tests give After Effects the audio output that `launch_ae.sh`
  gives it (`AEGNUX_TEST_AUDIO=auto`, the default: the machine's sound server, plus the silent
  stream of `scripts/sound_keepalive.sh` when its output is an RDP sink). `AEGNUX_TEST_AUDIO=host`
  uses the machine's sound server as it is (the cycles test fails on that server: the check that
  the fix is what makes it work), `null` a silent PulseAudio server of its own
  (`scripts/null_audio.sh`, needs `pulseaudio` and `pactl`) and `none` no audio device. About 3
  minutes.
- `run_pulse_resume_test.sh` runs the stream sequence of Wine's PulseAudio driver against the
  machine's sound server with a small Python program (`pulse_resume_test.py`, libpulse through
  ctypes): a stream is created corked, then three times it is uncorked, fed for three seconds,
  corked and left idle for seven seconds (the server suspends its output after five). A server that
  works answers at once and keeps asking for data. The RDP sink of the Direct3D 12 route's display
  stack does for the first round only; the second uncork is answered two seconds late or never and
  the stream takes a few percent of the data. The test then plays the silent stream of
  `sound_keepalive.sh` and repeats the sequence, which must work. It passes when the sequence works
  as it is, or with the silent stream, or when there is no sound server. About 30 to 70 seconds.
- `run_ae_text_test.sh` creates a text layer with the default font and measures the box of its text
  with `sourceRectAtTime`; a font without Latin letters measures 0 x 0. It passes at 100 x 50 or
  more. Without Myriad Pro in the prefix After Effects chose `NotoSansSignWriting` on a machine with
  the Noto fonts (see `docs/known-issues.md`); `ae_prefs.sh` copies Myriad Pro from After Effects'
  own folder. About 1.5 minutes.
- `run_ae_effects_test.sh` applies 40 common effects (blur, glow, colour, noise, distort, stylize
  and transform effects), each with one non-default parameter, renders frame 0 of each in CUDA
  mode and again in software mode, and compares both with a comp without the effect. It passes
  when every applied effect renders in both modes; the table shows which effects change the
  picture and how far the two modes differ. About 8 minutes.
- `run_push_descriptor_test.sh` checks that push descriptors reach a compute shader.
  `run_descriptor_features_test.sh` checks which descriptor features the Vulkan device supports:
  null buffer descriptors work, inline uniform blocks do not (see `docs/known-issues.md`).
- `run_robustness_test.sh` (no Wine, no After Effects) runs five compute shaders, each as its own
  process, for the VK_EXT_robustness2 behaviour that DXVK and vkd3d-proton rely on for Direct3D's
  out-of-range rules: a storage and a uniform buffer descriptor whose range is smaller than the
  buffer (reads inside the range return the data, reads past the range rounded up to the reported
  alignment return zero, writes past it are dropped), a 4x4 storage image (out-of-bounds `imageLoad`
  returns zero, an out-of-bounds `imageStore` writes nothing, no stray texel changes), and null
  storage image, sampled image and texel buffer descriptors (read as zero, the shader runs on). It
  found that dzn reported invalid size alignments (patch 22).
- `run_xfb_stub_test.sh` (no Wine, no After Effects) binds transform feedback buffers in two command
  buffers and passes when dzn prints its one warning line (patch 23).
- `run_d3d11_tessellation_test.sh` compiles a vertex, hull, domain and pixel shader with the prefix's
  `d3dcompiler_47.dll`, draws one tessellated quad through DXVK for the factors 1, 8 and 64 and
  counts its red pixels (about 2700 each time). DXVK clamps the factor to dzn's
  `maxTessellationGenerationLevel`, which was 0 before patch 24, and the hull shader it generates
  reads `gl_PatchVerticesIn`, which crashed `vkCreateGraphicsPipelines` before patch 25. About 1
  run in 12 ends with a crash message at process exit after the right frame (see
  `docs/known-issues.md`); the test reports that as a note. About 1 minute.
