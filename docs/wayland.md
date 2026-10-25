# After Effects on Wayland

NuxFX works in X11 sessions and in Wayland sessions (GNOME, KDE Plasma, sway, Hyprland and others).
After Effects runs through Wine's X11 driver, the setup everything here was verified with. On a
Wayland desktop that driver talks to **XWayland**, which these compositors start by default, so
there is nothing to configure.

## How the display driver is chosen

- `scripts/launch_ae.sh` looks at the session. When `DISPLAY` exists (X11, or XWayland in a Wayland
  session), Wine is told to use X11 and `WAYLAND_DISPLAY` is hidden from it. A Wine that sees both
  would pick its own Wayland driver, which was never tested with After Effects.
- When only `WAYLAND_DISPLAY` exists (a Wayland session without XWayland), Wine's Wayland driver is
  used and `scripts/doctor.sh` warns about it. Install `xwayland` (the package name is printed) to
  get the tested setup.
- `AEGNUX_WAYLAND=0` always uses X11, and `AEGNUX_WAYLAND=1` always uses Wine's Wayland driver.
- `ae_prefs.sh` writes the choice to `HKCU\Software\Wine\Drivers` before every start.

## What was tested

`tests/run_ae_wayland_test.sh` starts After Effects inside a private compositor with its own sockets
(`WAYLAND_DISPLAY` and `DISPLAY` both set, XWayland on), creates a comp with a red solid and an Invert
effect, and checks with a screenshot of the compositor that the Composition panel shows the rendered
cyan solid. Nothing of your running desktop is touched.

| Compositor | Command | Result |
|---|---|---|
| sway 1.9, headless backend (screenshot with `grim`) | `tests/run_ae_wayland_test.sh` | Passes: Wine loads `winex11`, 78522 cyan pixels. Four runs in a row; see below for the one that failed |
| KDE Plasma's KWin 5.27, virtual backend (screenshot with Spectacle) | `AEGNUX_TEST_COMPOSITOR=kwin tests/run_ae_wayland_test.sh` | Passes: Wine loads `winex11`, 78522 cyan pixels (the same picture as on sway) |

The KDE run needs `kwin_wayland` (Plasma 5.27 or newer), `dbus-run-session`, `spectacle` and ImageMagick.
KWin runs with OpenGL compositing on software OpenGL (Spectacle's screenshot interface needs OpenGL
compositing) and Xwayland without glamor (it crashes against a KWin that has no DRM device); the test
sets that for KWin only. The README's KDE screenshot comes from the same kind of KWin session with the
Plasma shell (panel, wallpaper) and Konsole started on top of it, and After Effects started with
`scripts/launch_ae.sh`.

One earlier sway run, the first after a run in which Wine's Wayland driver had failed to load, showed
no window within 150 s; it was not reproduced and its cause is not known.

Not tested: GNOME sessions, fractional scaling, HiDPI and several monitors.

## Wine's own Wayland driver

It is not recommended:

- The runner's `winewayland.so` calls `wl_display_create_queue_with_name`, which libwayland 1.23
  added. With libwayland-client 1.22 (Ubuntu 24.04) the driver fails to load; Wine logs "Application
  tried to create a window, but no driver could be loaded" and no window appears. `launch_ae.sh` and
  `doctor.sh` find this with `ldd -r` and say so.
- With a libwayland-client 1.23.1 (from Debian trixie, in `LD_LIBRARY_PATH` only), After Effects
  starts and draws its workspace in sway, but shows "Advanced 3D is not supported by the current
  hardware" at once. That warning does not appear on the X11 route. The cause was not examined.

Details and evidence: [known-issues.md](known-issues.md).
