#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# After Effects on a Wayland desktop. Starts a private compositor with XWayland and its own sockets,
# starts After Effects through scripts/launch_ae.sh the way a desktop session does (WAYLAND_DISPLAY
# and DISPLAY both set), lets a startup script make a comp with a red solid and an Invert effect, and
# passes if a screenshot of the compositor shows the cyan solid in the Composition panel.
#
#   AEGNUX_TEST_COMPOSITOR=sway   (default) sway with the headless backend; screenshot with grim
#   AEGNUX_TEST_COMPOSITOR=kwin   KDE Plasma's KWin with the virtual backend; screenshot with Spectacle
#   AEGNUX_WAYLAND unset or 0     Wine uses X11 through XWayland (the supported setup)
#   AEGNUX_WAYLAND=1              Wine uses its own Wayland driver (experimental)
#
# Nothing appears on your desktop: the compositor has no output device, its own sockets and (KWin) its
# own D-Bus session, and nothing of your running desktop is touched. Needs xdotool, xwininfo
# (x11-utils), Xwayland and python3, and for sway: sway and grim; for kwin: kwin_wayland (Plasma 5.27
# or newer), dbus-run-session, spectacle and ImageMagick. Any running After Effects of this prefix is
# stopped. The startup script is placed in "$AE_DIR/Scripts/Startup" and removed afterwards.
# Knobs: AEGNUX_TEST_DELAY (seconds before the comp is made, default 30), AEGNUX_TEST_WAIT (seconds
# to run After Effects, default 150), AEGNUX_TEST_LOGDIR (keeps the logs there).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S="$HERE/../scripts"
. "$S/common.sh"
WAIT="${AEGNUX_TEST_WAIT:-150}"
COMP="${AEGNUX_TEST_COMPOSITOR:-sway}"

case "$COMP" in
    sway) NEED="sway grim Xwayland xdotool xwininfo python3" ;;
    kwin) NEED="kwin_wayland dbus-run-session spectacle Xwayland xdotool xwininfo python3" ;;
    *) echo "FAIL: AEGNUX_TEST_COMPOSITOR must be sway or kwin (is: $COMP)"; exit 1 ;;
esac
for t in $NEED; do
    if ! command -v "$t" > /dev/null; then
        echo "FAIL: $t not installed ($(aegnux_pkg_hint xwayland xdotool x11-utils python3); sway: sway, grim; kwin: kwin_wayland from KDE Plasma, spectacle, ImageMagick)"
        exit 1
    fi
done
IM=""
if [ "$COMP" = kwin ]; then
    IM=$(command -v magick || command -v convert || true)
    if [ -z "$IM" ]; then echo "FAIL: ImageMagick (magick or convert) is needed to read Spectacle's PNG"; exit 1; fi
fi
if [ "${AEGNUX_DISABLE_CUDA:-0}" = 1 ]; then
    echo "FAIL: this test needs the CUDA bridge (AEGNUX_DISABLE_CUDA is 1)"
    exit 1
fi

WORK=$(mktemp -d) || exit 1
export XDG_RUNTIME_DIR="$WORK/run"
mkdir -m 700 "$XDG_RUNTIME_DIR"
# The compositor and everything it starts inherit these. The real desktop's sockets are not
# reachable from here, and the session variables of a desktop are the ones a launcher would see.
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK DBUS_SESSION_BUS_ADDRESS
export AEGNUX_COACHMARKS=0

U=$(aegnux_win_user)
JSX="$WINEPREFIX/drive_c/users/$U/aegnux_wayland_test.jsx"
STARTUP="$AE_DIR/Scripts/Startup/zz_aegnux_wayland_test.jsx"
COMP_PID=""
cleanup() {
    "$S/stop_ae.sh" > /dev/null 2>&1
    touch "$WORK/finish" 2> /dev/null
    # Only the process tree this test started: a compositor of your own session is never signalled.
    if [ -n "$COMP_PID" ]; then kill -TERM -- "-$COMP_PID" 2> /dev/null || kill "$COMP_PID" 2> /dev/null; fi
    if [ -n "${AEGNUX_TEST_LOGDIR:-}" ]; then
        mkdir -p "$AEGNUX_TEST_LOGDIR"
        cp "$WORK"/*.log "$WORK"/inner.env "$AEGNUX_TEST_LOGDIR/" 2> /dev/null
    fi
    rm -f "$STARTUP" "$JSX"
    sleep 1
    rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$JSX" << 'EOF'
app.beginUndoGroup("aegnux wayland test");
var comp = app.project.items.addComp("aegnux wayland test", 1920, 1080, 1.0, 10, 30);
var solid = comp.layers.addSolid([1, 0, 0], "Red Solid", 1200, 700, 1.0);
solid.property("ADBE Effect Parade").addProperty("ADBE Invert");
comp.openInViewer();
app.endUndoGroup();
EOF
# Startup scripts run before the workspace exists, so the test runs later.
printf 'app.scheduleTask("$.evalFile(new File(\x27C:/users/%s/aegnux_wayland_test.jsx\x27))", %s, false);\n' "$U" "$(( ${AEGNUX_TEST_DELAY:-30} * 1000 ))" > "$STARTUP"

if [ "$COMP" = sway ]; then
    # One headless output of 1920x1080, XWayland on, windows floating (After Effects and its dialogs
    # keep the size they ask for, as on a desktop that does not tile).
    cat > "$WORK/sway.conf" << 'EOF'
xwayland enable
default_border none
output HEADLESS-1 mode 1920x1080
for_window [shell="xwayland"] floating enable
for_window [app_id=".*"] floating enable
EOF
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
        sway -c "$WORK/sway.conf" > "$WORK/sway.log" 2>&1 &
    COMP_PID=$!
    for _ in $(seq 1 50); do
        ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock > /dev/null 2>&1 && ls "$XDG_RUNTIME_DIR"/wayland-* > /dev/null 2>&1 && break
        sleep 0.2
    done
    SOCK=$(ls "$XDG_RUNTIME_DIR"/wayland-* 2> /dev/null | grep -v '\.lock$' | head -n 1)
    SWAYSOCK=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock 2> /dev/null | head -n 1)
    if [ -z "$SOCK" ] || [ -z "$SWAYSOCK" ]; then
        echo "FAIL: the private sway did not start:"
        cat "$WORK/sway.log"
        exit 1
    fi
    export WAYLAND_DISPLAY=$(basename "$SOCK")
    export SWAYSOCK
    echo "compositor: sway on $WAYLAND_DISPLAY (XWayland on), AEGNUX_WAYLAND=${AEGNUX_WAYLAND:-unset}"
    if grep -q 'Failed to start Xwayland' "$WORK/sway.log"; then
        echo "FAIL: sway could not start XWayland (a desktop's /tmp/.X11-unix has mode 1777, see /tmp/.X11-unix):"
        grep -i 'xwayland' "$WORK/sway.log" | head -n 3
        exit 1
    fi
    # After Effects is started by the compositor, so it sees the environment of a session inside it:
    # WAYLAND_DISPLAY and DISPLAY (XWayland's, set by sway) both exist.
    cat > "$WORK/inner.sh" << EOF
#!/bin/bash
env > "$WORK/inner.env"
exec "$S/launch_ae.sh" $((WAIT + 20)) > "$WORK/launch.log" 2>&1
EOF
    swaymsg exec "bash $WORK/inner.sh" > /dev/null
else
    # KWin runs the session script with WAYLAND_DISPLAY and DISPLAY set (KWin starts XWayland). Software
    # OpenGL is for KWin only: Spectacle's screenshot interface needs OpenGL compositing, and Xwayland's
    # glamor crashes against a KWin that has no DRM device.
    cat > "$WORK/session.sh" << EOF
#!/bin/bash
unset LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER KWIN_COMPOSE XWAYLAND_NO_GLAMOR
env > "$WORK/inner.env"
bash "$S/launch_ae.sh" $((WAIT + 20)) > "$WORK/launch.log" 2>&1 &
sleep $WAIT
spectacle -b -n -f -o "$WORK/screen.png" > "$WORK/spectacle.log" 2>&1
touch "$WORK/shot.done"
while [ ! -e "$WORK/finish" ]; do sleep 1; done
EOF
    chmod +x "$WORK/session.sh"
    echo "compositor: KWin (virtual backend, XWayland on), AEGNUX_WAYLAND=${AEGNUX_WAYLAND:-unset}"
    KWIN_COMPOSE=O2 LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe XWAYLAND_NO_GLAMOR=1 \
    XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=KDE KDE_FULL_SESSION=true \
        setsid dbus-run-session -- kwin_wayland --virtual --width 1920 --height 1080 --xwayland \
        --socket wayland-nuxfx-test --no-lockscreen --no-global-shortcuts --no-kactivities \
        --exit-with-session "$WORK/session.sh" > "$WORK/kwin.log" 2>&1 &
    COMP_PID=$!
    for _ in $(seq 1 60); do grep -q '^DISPLAY=' "$WORK/inner.env" 2> /dev/null && break; sleep 1; done
    if ! grep -q '^DISPLAY=' "$WORK/inner.env" 2> /dev/null; then
        echo "FAIL: KWin did not start a session with XWayland:"
        tail -n 8 "$WORK/kwin.log"
        exit 1
    fi
fi

# Dismiss the windows that wait for input: 430x211 ("Advanced 3D is not supported"), 494x200 (Crash
# Repair Options) and Adobe's System Compatibility Report. They are X windows and show up on the X
# display of XWayland; with Wine's Wayland driver there is nothing to find.
T=0
while [ "$T" -lt "$WAIT" ]; do
    sleep 10
    T=$((T + 10))
    XD=$(sed -n 's/^DISPLAY=//p' "$WORK/inner.env" 2> /dev/null | head -n 1)
    [ -n "$XD" ] || continue
    for X in $(DISPLAY="$XD" xdotool search --onlyvisible --class afterfx 2> /dev/null); do
        case "$(DISPLAY="$XD" xwininfo -id "$X" 2> /dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')" in
            430x211|494x200) DISPLAY="$XD" xdotool key --window "$X" Return 2> /dev/null ;;
        esac
    done
    for X in $(DISPLAY="$XD" xdotool search --onlyvisible --name "System Compatibility Report" 2> /dev/null); do
        DISPLAY="$XD" xdotool mousemove --window "$X" 437 481 click 1 2> /dev/null
    done
done

# Which Wine display driver is loaded into After Effects?
DRV=none
for pid in $(aegnux_prefix_pids 'AfterFX[.]exe'); do
    if grep -q 'winewayland[.]so' "/proc/$pid/maps" 2> /dev/null; then DRV=wayland; fi
    if grep -q 'winex11[.]so' "/proc/$pid/maps" 2> /dev/null; then DRV=x11; fi
done
echo "Wine display driver in After Effects: $DRV"

if [ "$COMP" = sway ]; then
    grim -t ppm "$WORK/screen.ppm" 2> "$WORK/grim.log"
    if [ ! -s "$WORK/screen.ppm" ]; then
        echo "FAIL: grim could not capture the compositor:"
        cat "$WORK/grim.log"
        exit 1
    fi
else
    for _ in $(seq 1 60); do [ -e "$WORK/shot.done" ] && break; sleep 1; done
    if [ ! -s "$WORK/screen.png" ]; then
        echo "FAIL: Spectacle could not capture KWin:"
        tail -n 6 "$WORK/spectacle.log"
        exit 1
    fi
    "$IM" "$WORK/screen.png" -depth 8 "ppm:$WORK/screen.ppm" || { echo "FAIL: ImageMagick could not read the screenshot"; exit 1; }
fi
mkdir -p "$AEGNUX_TEST_DIR"
cp "$WORK/screen.ppm" "$AEGNUX_TEST_DIR/ae_wayland_test.ppm"

python3 - "$WORK/screen.ppm" << 'PY'
import sys
data = open(sys.argv[1], 'rb').read()
fields, pos = [], 0
while len(fields) < 4:
    while data[pos:pos + 1].isspace():
        pos += 1
    start = pos
    while not data[pos:pos + 1].isspace():
        pos += 1
    fields.append(data[start:pos])
pix = data[pos + 1:]
cyan = red = 0
for i in range(0, len(pix) - 2, 3):
    r, g, b = pix[i], pix[i + 1], pix[i + 2]
    if r < 40 and g > 215 and b > 215:
        cyan += 1
    elif r > 215 and g < 40 and b < 40:
        red += 1
print(f"cyan pixels {cyan}, red pixels {red}, screen {fields[1].decode()}x{fields[2].decode()}")
sys.exit(0 if cyan > 20000 else 1)
PY
RC=$?
if [ "$RC" -eq 0 ]; then
    echo "PASS: the Composition panel shows the rendered comp on a Wayland compositor ($COMP, Wine driver: $DRV)"
else
    echo "FAIL: the Composition panel does not show the comp on a Wayland compositor ($COMP, Wine driver: $DRV; screen: $AEGNUX_TEST_DIR/ae_wayland_test.ppm)"
fi
exit "$RC"
