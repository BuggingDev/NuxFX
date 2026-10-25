# Configuration

Each setting comes from the environment. If it is not set there, it comes from
`~/.config/aegnux/aegnux.conf` (plain `KEY=value` lines; `AEGNUX_CONFIG` points elsewhere). If it
is not there either, the default in `scripts/common.sh` is used. The code and the configuration
keep the `aegnux` name (`AEGNUX_*`, `~/.local/share/aegnux`), as in
[AEGNUX](https://github.com/relativemodder/aegnux), which NuxFX is based on.

| Variable | Default | Meaning |
|---|---|---|
| `AEGNUX_HOME` | `~/.local/share/aegnux` | Data folder |
| `WINE_BIN_DIR` | `$AEGNUX_HOME/runner/bin` | Wine runner |
| `WINEPREFIX` | `$AEGNUX_HOME/wineprefix` | Wine prefix |
| `AE_DIR` | `$AEGNUX_HOME/AE` | Folder that contains `AfterFX.exe` |
| `AEGNUX_WAYLAND` | `auto` | `auto`: X11 when `DISPLAY` exists (XWayland on a Wayland desktop), Wine's Wayland driver only when it does not. `0`: always X11. `1`: always Wine's Wayland driver (not recommended, see [wayland.md](wayland.md)) |
| `AEGNUX_VULKAN` | `auto` | `dzn`, `system` or `auto` (dzn on the Direct3D 12 route, the host's driver elsewhere) |
| `AEGNUX_D3D12_LIBDIR` | `/usr/lib/wsl/lib` | Where the GPU driver of the Direct3D 12 route installs `libd3d12.so`, `libdxcore.so` and `libcuda.so.1` (`doctor.sh` and `install.sh` look there) |
| `DZN_PREFIX` | `$AEGNUX_HOME/dzn` | dzn install, written by `build_dzn.sh` |
| `AEGNUX_GL_PREFIX` | `$AEGNUX_HOME/mesa-gl` | Install of `scripts/build_gl.sh` (Mesa's EGL and d3d12 OpenGL driver). Used first when it exists on the Direct3D 12 route |
| `AEGNUX_SYSTEM_GL` | `0` | `1` uses the distribution's OpenGL even when `AEGNUX_GL_PREFIX` exists |
| `AEGNUX_REP_MOVSB` | `0` | `1` keeps glibc's `memcpy` on `rep movsb`. By default, on the Direct3D 12 route, `aegnux_env` sets a glibc tunable that avoids it: with `rep movsb` RAM preview ran at a fifth of real time |
| `AEGNUX_DISABLE_CUDA` | `0` | `1` turns CUDA off for After Effects. It then renders in software and reports Advanced 3D as unsupported |
| `AEGNUX_DIRECTX_DISPLAY` | `0` | `1` keeps After Effects' DirectX display, and switches it back on where an earlier start disabled it (the panel stays empty while CUDA is used) |
| `AEGNUX_DEFAULT_FONT` | `1` | `0` does not copy After Effects' own `pdfl/Fonts/MyriadPro-Regular.otf` into the prefix's Fonts folder (see the preferences below) |
| `AEGNUX_SOUND_KEEPALIVE` | `auto` | RAM preview breaks on the sound server of the Direct3D 12 route's display stack: its output suspends after five idle seconds and does not resume the audio stream that After Effects opened at its start. `auto`: when an output of the sound server is an RDP sink, `launch_ae.sh` plays a silent stream for as long as After Effects runs (`scripts/sound_keepalive.sh`: `pacat` from `pulseaudio-utils` when it is installed, otherwise `python3` with `scripts/tools/silent_stream.py`), sound included. `0` never, `1` always (for a sound server that behaves the same way). Without both After Effects is told there is no audio device (`doctor.sh` warns) |
| `AEGNUX_AUDIO_DEVICES` | `1` | `0` tells After Effects there is no audio device (`dvaaudiodevice.ForceNoDevices`): it plays no sound and opens no audio stream, RAM preview works |
| `AEGNUX_NULL_AUDIO` | `0` | `1` gives After Effects a silent audio output from a PulseAudio server of its own (`scripts/null_audio.sh`; `launch_ae.sh` starts and stops it, and `aegnux_env` points `PULSE_SERVER` at it) and leaves the machine's sound server alone. Needs `pulseaudio` and `pactl`. `AEGNUX_AUDIO_RUN` moves the folder of that server and of the pid files of `sound_keepalive.sh` |
| `AEGNUX_HIDE_HOME_SCREEN` | `1` | `0` keeps After Effects' Home screen setting. On a first start `ae_prefs.sh` writes a preferences file with the Home screen off |
| `AEGNUX_COACHMARKS` | `1` | `0` switches off the first-start tips (the tests use it) |
| `AEGNUX_SCRIPT_FILE_ACCESS` | `0` | `1` switches on "Allow Scripts to Write Files and Access Network" in After Effects' preferences (`ae_prefs.sh` sets `Pref_SCRIPTING_FILE_NETWORK_SECURITY`). Off by default, as in After Effects; the text and effects tests set it, because their startup script reports its result through a file |
| `AEGNUX_EXTRA_OVERRIDES` | empty | Extra `WINEDLLOVERRIDES` entries |
| `AEGNUX_WINEDEBUG` | errors only | `WINEDEBUG` for After Effects |
| `AEGNUX_APIVER_LAYER` | `0` | `1` enables the optional apiVersion layer (not needed with patch 04) |

## Preferences set by `scripts/ae_prefs.sh`

`launch_ae.sh` runs `ae_prefs.sh` before every start. It is idempotent.

| Setting | Why | Opt out |
|---|---|---|
| `DS.DisableDirectXDisplay = true` (Debug Database) | With CUDA available, After Effects shows Composition panel frames through its DirectX display, which passes images between CUDA and Direct3D 12. The CUDA bridge cannot share those resources, so the panel stayed empty. | `AEGNUX_DIRECTX_DISPLAY=1` |
| `dvaaudiodevice.ForceNoDevices = true` (Debug Database), only when the audio plan is `nodevice` | After Effects is told there is no audio device. Set when the sound output is an RDP sink and neither `pacat` nor `python3` is installed, or with `AEGNUX_AUDIO_DEVICES=0`; set back to `false` on every start when it is not needed. | install `python3` (or `pulseaudio-utils`), or `AEGNUX_SOUND_KEEPALIVE=0` |
| `"Show Welcome Screen" = 00` (Prefs) | The HTML Home screen renders as an empty panel that covers the workspace. | `AEGNUX_HIDE_HOME_SCREEN=0` |
| `HKCU\Software\Wine\Drivers` `Graphics` = `x11` or `wayland` | Pins the Wine display driver to the one that `launch_ae.sh` chose for the session (see [wayland.md](wayland.md)). | `AEGNUX_WAYLAND` |
| `drive_c/windows/Fonts/MyriadPro-Regular.otf` in the prefix | After Effects' default font for new text layers is Myriad Pro. Without it in the prefix, After Effects picks a font of its own, and with many fonts installed (Noto) that was `NotoSansSignWriting`, which has no Latin letters: new text looked empty. The file is copied from After Effects' own `pdfl/Fonts` folder. | `AEGNUX_DEFAULT_FONT=0` |
