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

`tests/run_ae_wayland_test.sh` starts After Effects inside a private, headless sway compositor
(`WAYLAND_DISPLAY` and `DISPLAY` both set, XWayland on, its own sockets), creates a comp with a red
solid and an Invert effect, and checks with `grim` that the Composition panel shows the rendered
cyan solid. It passed in four runs in a row, with Wine's X11 driver loaded. One earlier run, the
first after a run in which Wine's Wayland driver had failed to load, showed no window within 150 s;
it was not reproduced and its cause is not known.

Not tested: GNOME and KDE Plasma sessions, fractional scaling, HiDPI and several monitors.

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
