#!/bin/bash
# End-to-end check of the Composition panel. Starts After Effects with a temporary
# startup script that creates a comp with a red solid and an Invert effect and opens
# it, captures the screen and passes if the panel shows the inverted (cyan) solid.
#
# Runs on a private Xvfb display when Xvfb is installed, so nothing appears on the
# desktop and no input can interfere (AEGNUX_TEST_XVFB=0 uses the current DISPLAY).
# Requires xdotool, xwininfo, python3 and gcc with X11 headers. The startup script
# is placed in "$AE_DIR/Scripts/Startup" and removed afterwards. Any running After
# Effects of this prefix is stopped.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S="$HERE/../scripts"
. "$S/common.sh"
WAIT="${AEGNUX_TEST_WAIT:-150}"

for t in xdotool xwininfo python3 gcc; do
    if ! command -v "$t" > /dev/null; then
        echo "FAIL: $t not installed ($(aegnux_pkg_hint xdotool x11-utils python3 gcc libx11-dev))"
        exit 1
    fi
done
WORK=$(mktemp -d) || exit 1
gcc -O1 -o "$WORK/xcap" "$S/tools/xcap.c" -lX11 || exit 1

XVFB_PID=""
if [ "${AEGNUX_TEST_XVFB:-1}" = 1 ] && command -v Xvfb > /dev/null; then
    N=99
    while [ -e "/tmp/.X$N-lock" ]; do N=$((N - 1)); done
    Xvfb ":$N" -screen 0 1920x1080x24 -nolisten tcp > /dev/null 2>&1 &
    XVFB_PID=$!
    export DISPLAY=":$N"
    sleep 2
else
    echo "note: using DISPLAY=${DISPLAY:-}; do not touch the After Effects window during the test"
fi

U=$(aegnux_win_user)
JSX="$WINEPREFIX/drive_c/users/$U/aegnux_viewer_test.jsx"
STARTUP="$AE_DIR/Scripts/Startup/zz_aegnux_viewer_test.jsx"
cleanup() {
    rm -f "$STARTUP" "$JSX"
    "$S/stop_ae.sh" > /dev/null 2>&1
    if [ -n "$XVFB_PID" ]; then kill "$XVFB_PID" 2> /dev/null; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$JSX" << 'EOF'
app.beginUndoGroup("aegnux viewer test");
var comp = app.project.items.addComp("aegnux viewer test", 1920, 1080, 1.0, 10, 30);
var solid = comp.layers.addSolid([1, 0, 0], "Red Solid", 1200, 700, 1.0);
solid.property("ADBE Effect Parade").addProperty("ADBE Invert");
comp.openInViewer();
app.endUndoGroup();
EOF
# Startup scripts run before the workspace exists, so the test runs 30 s later.
printf 'app.scheduleTask("$.evalFile(new File(\x27C:/users/%s/aegnux_viewer_test.jsx\x27))", 30000, false);\n' "$U" > "$STARTUP"

"$S/stop_ae.sh" > /dev/null 2>&1
"$S/clear_crash_state.sh" > /dev/null
"$S/ae_prefs.sh" > /dev/null
aegnux_env
cd "$AE_DIR" || exit 1
timeout $((WAIT + 30)) wine AfterFX.exe > "$WORK/out.log" 2> "$WORK/err.log" < /dev/null &
disown $!

T=0
while [ "$T" -lt "$WAIT" ]; do
    sleep 10
    T=$((T + 10))
    # "Advanced 3D is not supported by the current hardware" (CUDA hidden) waits for OK.
    for X in $(xdotool search --onlyvisible --class afterfx 2> /dev/null); do
        if [ "$(xwininfo -id "$X" 2> /dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')" = 430x211 ]; then
            xdotool key --window "$X" Return 2> /dev/null
        fi
    done
done

if [ -n "$XVFB_PID" ]; then
    TARGET=$(xwininfo -root | awk '/Window id:/{print $4}')
else
    TARGET=$(xdotool search --name "Adobe After Effects" 2> /dev/null | head -n 1)
fi
if [ -z "$TARGET" ] || ! "$WORK/xcap" "$TARGET" "$WORK/screen.ppm" > /dev/null; then
    echo "FAIL: could not capture the After Effects window"
    exit 1
fi
mkdir -p "$AEGNUX_TEST_DIR"
cp "$WORK/screen.ppm" "$AEGNUX_TEST_DIR/ae_viewer_test.ppm"

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
print(f"cyan pixels {cyan}, red pixels {red}")
sys.exit(0 if cyan > 20000 else 1)
PY
RC=$?
if [ "$RC" -eq 0 ]; then
    echo "PASS: the Composition panel shows the rendered comp"
else
    echo "FAIL: the Composition panel does not show the comp (screen: $AEGNUX_TEST_DIR/ae_viewer_test.ppm)"
fi
exit "$RC"