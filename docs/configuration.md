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
| `DZN_PREFIX` | `$AEGNUX_HOME/dzn` | dzn install, written by `build_dzn.sh` |
| `AEGNUX_GL_PREFIX` | `$AEGNUX_HOME/mesa-gl` | Install of `scripts/build_gl.sh` (Mesa's EGL and d3d12 OpenGL driver). Used first when it exists on the Direct3D 12 route |
| `AEGNUX_SYSTEM_GL` | `0` | `1` uses the distribution's OpenGL even when `AEGNUX_GL_PREFIX` exists |
| `AEGNUX_REP_MOVSB` | `0` | `1` keeps glibc's `memcpy` on `rep movsb`. By default, on the Direct3D 12 route, `aegnux_env` sets a glibc tunable that avoids it: with `rep movsb` RAM preview ran at a fifth of real time |
| `AEGNUX_DISABLE_CUDA` | `0` | `1` turns CUDA off for After Effects. It then renders in software and reports Advanced 3D as unsupported |
| `AEGNUX_DIRECTX_DISPLAY` | `0` | `1` keeps After Effects' DirectX display (the panel stays empty while CUDA is used) |
| `AEGNUX_HIDE_HOME_SCREEN` | `1` | `0` keeps After Effects' Home screen setting. On a first start `ae_prefs.sh` writes a preferences file with the Home screen off |
| `AEGNUX_COACHMARKS` | `1` | `0` switches off the first-start tips (the tests use it) |
| `AEGNUX_EXTRA_OVERRIDES` | empty | Extra `WINEDLLOVERRIDES` entries |
| `AEGNUX_WINEDEBUG` | errors only | `WINEDEBUG` for After Effects |
| `AEGNUX_APIVER_LAYER` | `0` | `1` enables the optional apiVersion layer (not needed with patch 04) |

## Preferences set by `scripts/ae_prefs.sh`

`launch_ae.sh` runs `ae_prefs.sh` before every start. It is idempotent.

| Setting | Why | Opt out |
|---|---|---|
| `DS.DisableDirectXDisplay = true` (Debug Database) | With CUDA available, After Effects shows Composition panel frames through its DirectX display, which passes images between CUDA and Direct3D 12. The CUDA bridge cannot share those resources, so the panel stayed empty. | `AEGNUX_DIRECTX_DISPLAY=1` |
| `"Show Welcome Screen" = 00` (Prefs) | The HTML Home screen renders as an empty panel that covers the workspace. | `AEGNUX_HIDE_HOME_SCREEN=0` |
| `HKCU\Software\Wine\Drivers` `Graphics` = `x11` or `wayland` | Pins the Wine display driver to the one that `launch_ae.sh` chose for the session (see [wayland.md](wayland.md)). | `AEGNUX_WAYLAND` |
