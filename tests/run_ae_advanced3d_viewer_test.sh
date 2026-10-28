#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Advanced 3D in the Composition panel. The scene tests render to files; this test shows a 1920x1080
# Advanced 3D comp (extruded text, a wall, two point lights, an Environment light with shadows) in
# the viewer and then clicks the Draft 3D button of the viewer twice, which renders the frame again
# each time. The viewer shows the frame through shared D3D11 textures with a keyed mutex; before
# patch 21 the click ended with "After Effects error: Crash in progress. Last logged message was:
# <3D.Tiling> Tile size Y: ..." because dzn could not import the semaphore of the keyed mutex and
# DXVK threw. (CompItem.draft3d in a script does not take that path, so the test clicks.)
#
# Passes when After Effects is still running after both clicks, no error box appeared, and the viewer
# shows the orange 3D text before and after the clicks. The click position is a fraction of the main
# window; it is right for the private 1920x1080 display and the default workspace that the test uses.
# Knobs (all optional): AEGNUX_TEST_DELAY (seconds before the scene is built, default 30),
# AEGNUX_TEST_WAIT (seconds to wait for the scene, default 240), AEGNUX_TEST_LOGDIR.
# Runs on a private Xvfb display only (AEGNUX_TEST_XVFB must stay 1). Needs the CUDA bridge,
# xdotool, xwininfo, python3 and gcc with X11 headers. Any running After Effects of this prefix is
# stopped.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S="$HERE/../scripts"
. "$S/common.sh"
WAIT="${AEGNUX_TEST_WAIT:-240}"
DELAY="${AEGNUX_TEST_DELAY:-30}"
OUT="$AEGNUX_TEST_DIR/advanced3d_viewer"

for t in xdotool xwininfo python3 gcc; do
    if ! command -v "$t" > /dev/null; then
        echo "FAIL: $t not installed ($(aegnux_pkg_hint xdotool x11-utils python3 gcc libx11-dev))"
        exit 1
    fi
done
if [ "${AEGNUX_TEST_XVFB:-1}" != 1 ] || ! command -v Xvfb > /dev/null; then
    echo "FAIL: this test runs on a private Xvfb only (AEGNUX_TEST_XVFB must be 1 and Xvfb installed)"
    exit 1
fi
if [ "${AEGNUX_DISABLE_CUDA:-0}" = 1 ]; then
    echo "FAIL: Advanced 3D needs the CUDA bridge (AEGNUX_DISABLE_CUDA is 1)"
    exit 1
fi
WORK=$(mktemp -d) || exit 1
gcc -O1 -o "$WORK/xcap" "$S/tools/xcap.c" -lX11 || exit 1

N=99
while [ -e "/tmp/.X$N-lock" ] || grep -q "@/tmp/.X11-unix/X$N\$" /proc/net/unix 2> /dev/null; do N=$((N - 1)); done
Xvfb ":$N" -screen 0 1920x1080x24 -nolisten tcp > /dev/null 2>&1 &
XVFB_PID=$!
export DISPLAY=":$N"
for _ in $(seq 1 50); do xwininfo -root > /dev/null 2>&1 && break; sleep 0.2; done
xwininfo -root > /dev/null 2>&1 || { echo "FAIL: Xvfb did not start on $DISPLAY"; kill "$XVFB_PID" 2> /dev/null; exit 1; }
unset WAYLAND_DISPLAY

U=$(aegnux_win_user)
USERDIR="$WINEPREFIX/drive_c/users/$U"
PROJECT="$USERDIR/aegnux_a3dv_result.aep"
JSX="$USERDIR/aegnux_a3dv_build.jsx"
STARTUP="$AE_DIR/Scripts/Startup/zz_aegnux_a3dv_test.jsx"
DISMISS_PID=""
cleanup() {
    [ -n "$DISMISS_PID" ] && kill "$DISMISS_PID" 2> /dev/null
    if [ -n "${AEGNUX_TEST_LOGDIR:-}" ]; then
        mkdir -p "$AEGNUX_TEST_LOGDIR"
        cp "$WORK/out.log" "$WORK/err.log" "$WORK/dialogs.log" "$WORK/windows.log" "$AEGNUX_TEST_LOGDIR/" 2> /dev/null
    fi
    rm -f "$STARTUP" "$JSX" "$PROJECT"
    "$S/stop_ae.sh" > /dev/null 2>&1
    kill "$XVFB_PID" 2> /dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
rm -f "$PROJECT"
mkdir -p "$OUT"
rm -f "$OUT"/*.ppm "$OUT"/*.log "$OUT"/*.txt

printf 'var PROJECT_PATH = "C:/users/%s/aegnux_a3dv_result.aep";\n' "$U" > "$JSX"
cat >> "$JSX" << 'EOF'
// ExtendScript is ECMAScript 3: var only, no arrow functions, no trailing commas.
function mark(name) {
    app.project.items.addComp("V3D__" + name, 16, 16, 1.0, 1, 30);
    app.project.save(new File(PROJECT_PATH));
}
function findProp(group, needle, depth) {
    var n = needle.toLowerCase();
    var d = depth || 0;
    if (d > 6) { return null; }
    for (var i = 1; i <= group.numProperties; i++) {
        var p = group.property(i);
        if (p.propertyType == PropertyType.PROPERTY) {
            if (String(p.matchName).toLowerCase().indexOf(n) >= 0 || String(p.name).toLowerCase().indexOf(n) >= 0) { return p; }
        } else {
            var r = findProp(p, needle, d + 1);
            if (r) { return r; }
        }
    }
    return null;
}
function setIf(p, v) { try { if (p) { p.setValue(v); } } catch (e) { } }
try {
    var W = 1920, H = 1080;
    var c = app.project.items.addComp("aegnux a3d viewer", W, H, 1.0, 6, 30);
    c.renderer = "ADBE Calder";
    c.bgColor = [0.02, 0.025, 0.04];
    // Casts Shadows on a layer: 2 is "Only" (the layer is not drawn); 1 draws the layer and casts.
    var wall = c.layers.addSolid([0.10, 0.12, 0.18], "Wall", W * 3, H * 3, 1.0);
    wall.threeDLayer = true;
    wall.property("ADBE Transform Group").property("ADBE Position").setValue([960, 540, 600]);
    setIf(findProp(wall, "Accepts Shadows"), 1);
    var tl = c.layers.addText("LINUX");
    tl.threeDLayer = true;
    var doc = tl.property("ADBE Text Properties").property("ADBE Text Document");
    var td = doc.value;
    td.fontSize = 300;
    td.fillColor = [0.93, 0.36, 0.14];
    td.applyFill = true;
    td.justification = ParagraphJustification.CENTER_JUSTIFY;
    doc.setValue(td);
    tl.property("ADBE Transform Group").property("ADBE Position").setValue([960, 650, 0]);
    tl.property("ADBE Transform Group").property("ADBE Orientation").setValue([10, -24, 0]);
    setIf(findProp(tl, "Extrsn Depth"), 110);
    setIf(findProp(tl, "Accepts Shadows"), 1);
    setIf(findProp(tl, "Casts Shadows"), 1);
    var cam = c.layers.addCamera("Camera", [960, 540]);
    cam.property("ADBE Transform Group").property("ADBE Position").setValue([960, 540, -1800]);
    var key = c.layers.addLight("Key", [960, 540]);
    key.lightType = LightType.POINT;
    key.property("ADBE Transform Group").property("ADBE Position").setValue([230, 110, -900]);
    setIf(findProp(key, "Light Intensity"), 200);
    setIf(findProp(key, "Color"), [1.0, 0.9, 0.78]);
    var fill = c.layers.addLight("Fill", [960, 540]);
    fill.lightType = LightType.POINT;
    fill.property("ADBE Transform Group").property("ADBE Position").setValue([1730, 970, -800]);
    setIf(findProp(fill, "Light Intensity"), 90);
    setIf(findProp(fill, "Color"), [0.4, 0.6, 1.0]);
    var env = c.layers.addLight("Environment", [960, 540]);
    env.lightType = LightType.ENVIRONMENT;
    setIf(findProp(env, "Light Intensity"), 60);
    setIf(findProp(env, "Casts Shadows"), 1);
    c.time = 0;
    c.openInViewer();
    mark("built");
} catch (e) {
    app.project.items.addComp("V3D__fatal__" + String(e).replace(/[^A-Za-z0-9]/g, "_").substring(0, 80), 16, 16, 1.0, 1, 30);
    app.project.save(new File(PROJECT_PATH));
}
EOF
printf 'app.scheduleTask("$.evalFile(new File(\x27C:/users/%s/aegnux_a3dv_build.jsx\x27))", %s, false);\n' "$U" "$((DELAY * 1000))" > "$STARTUP"

"$S/stop_ae.sh" > /dev/null 2>&1
"$S/clear_crash_state.sh" > /dev/null
AEGNUX_COACHMARKS=0 "$S/ae_prefs.sh" > /dev/null
export WINEDEBUG="${AEGNUX_A3D_WINEDEBUG:-err+all,warn+vulkan}"
aegnux_env
cd "$AE_DIR" || exit 1
timeout $((WAIT + 200)) wine AfterFX.exe > "$WORK/out.log" 2> "$WORK/err.log" < /dev/null &
disown $!

# Dialogs: 430x211 (Advanced 3D not supported), 494x200 (Crash Repair Options), 494x141 (warning box)
# get Return. Every window size and title seen is logged; the error box of a crash (title
# "After Effects") is only logged, so that the test sees it.
(
    while :; do
        sleep 3
        for X in $(xdotool search --onlyvisible --class afterfx 2> /dev/null); do
            SZ=$(xwininfo -id "$X" 2> /dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')
            NAME=$(xdotool getwindowname "$X" 2> /dev/null | tr -d '\n')
            grep -qxF "$SZ $NAME" "$WORK/windows.log" 2> /dev/null || echo "$SZ $NAME" >> "$WORK/windows.log"
            case "$SZ" in
                430x211|494x200|494x141)
                    echo "$(date +%T) dismissed $SZ $NAME" >> "$WORK/dialogs.log"
                    xdotool key --window "$X" Return 2> /dev/null ;;
            esac
        done
        for X in $(xdotool search --onlyvisible --name "System Compatibility Report" 2> /dev/null); do
            echo "$(date +%T) clicked the System Compatibility Report" >> "$WORK/dialogs.log"
            xdotool mousemove --window "$X" 437 481 click 1 2> /dev/null
        done
    done
) &
DISMISS_PID=$!

TARGET=$(xwininfo -root | awk '/Window id:/{print $4}')
alive() { [ -n "$(aegnux_prefix_pids 'AfterFX[.]exe')" ]; }
capture() { "$WORK/xcap" "$TARGET" "$OUT/$1.ppm" > /dev/null 2>&1; }

# The scene is built by the startup script some time after the start; its marker is in the project.
T=0
while [ "$T" -lt "$WAIT" ]; do
    sleep 3
    T=$((T + 3))
    grep -q -a -E 'V3D__(built|fatal)' "$PROJECT" 2> /dev/null && break
    if [ "$T" -ge 40 ] && ! alive; then
        echo "note: After Effects exited before the scene was built"
        break
    fi
done
sleep 45
capture before

# The Draft 3D button of the viewer, as a fraction of the main window (measured on this display).
# After Effects 26 has another layout: Draft 3D is the lightning bolt at the top left of the Timeline panel (21 % of the window
# width, 74 % of its height).
case "$(aegnux_ae_version)" in
    2[6-9].*|[3-9][0-9].*) DRAFT_X=207; DRAFT_Y=742 ;;
    *) DRAFT_X=628; DRAFT_Y=692 ;;
esac
click_draft() {
    local wid x y w h
    wid=$(xdotool search --onlyvisible --name "Adobe After Effects 20[0-9][0-9]" 2> /dev/null | head -n 1)
    if [ -z "$wid" ]; then echo "note: the main window was not found"; return 1; fi
    eval "$(xdotool getwindowgeometry --shell "$wid")"
    x=$((X + WIDTH * DRAFT_X / 1000))
    y=$((Y + HEIGHT * DRAFT_Y / 1000))
    echo "clicking Draft 3D at $x,$y (main window ${WIDTH}x${HEIGHT}+$X+$Y)"
    xdotool mousemove "$x" "$y" click 1
}
CLICKED=0
if alive; then
    click_draft && CLICKED=1
    sleep 30
    capture draft_on
    if alive; then
        click_draft
        sleep 30
    fi
fi
capture final
ALIVE=0
alive && ALIVE=1
kill "$DISMISS_PID" 2> /dev/null
DISMISS_PID=""
[ -f "$PROJECT" ] && cp "$PROJECT" "$OUT/result.aep"
cp "$WORK/dialogs.log" "$WORK/windows.log" "$OUT/" 2> /dev/null
grep -a -E 'DxvkError|Failed to import|terminate called|Unhandled exception|page fault|c0000005|device lost|DEVICE_LOST' "$WORK/err.log" | sed -E 's/0x[0-9a-f]+/0xN/g' | sort | uniq -c | sort -rn > "$OUT/wine_lines.txt" 2> /dev/null
ERRBOX=$(grep -c -E '^[0-9]+x[0-9]+ After Effects$' "$WORK/windows.log" 2> /dev/null)
echo "After Effects running at the end: $ALIVE; error boxes seen: ${ERRBOX:-0}; Draft 3D clicked: $CLICKED; Wine lines about a DXVK error, an exception or a lost device: $(wc -l < "$OUT/wine_lines.txt")"

python3 -I - "$OUT" "$PROJECT" "$ALIVE" "${ERRBOX:-0}" "$CLICKED" << 'PY'
import os, re, sys

OUT, AEP = sys.argv[1], sys.argv[2]
ALIVE, ERRBOX, CLICKED = sys.argv[3] == '1', int(sys.argv[4]), sys.argv[5] == '1'


def orange(path):
    if not os.path.exists(path):
        return None
    data = open(path, 'rb').read()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    pix = data[pos + 1:]
    n = 0
    for i in range(0, len(pix) - 2, 3):
        r, g, b = pix[i], pix[i + 1], pix[i + 2]
        if r > 180 and 60 < g < 160 and b < 90 and r - g > 60:
            n += 1
    return n


blob = open(AEP, 'rb').read() if os.path.exists(AEP) else b''
marks = []
for raw in re.findall(rb'V3D__[A-Za-z0-9_]+', blob):
    text = raw.decode()
    if text.endswith('LIST'):
        text = text[:-4]
    name = text[len('V3D__'):]
    if name not in marks:
        marks.append(name)
print('script steps seen: ' + (', '.join(marks) if marks else 'none'))
before, mid, final = (orange(os.path.join(OUT, n + '.ppm')) for n in ('before', 'draft_on', 'final'))
print('orange pixels: before the clicks %s, after the first click %s, after the second %s' % (before, mid, final))
problems = []
if 'built' not in marks:
    problems.append('the scene was not built')
if not CLICKED:
    problems.append('the Draft 3D button was not clicked')
if not ALIVE:
    problems.append('After Effects is not running (it crashed)')
if ERRBOX:
    problems.append('an After Effects error box appeared (%d)' % ERRBOX)
if before is None or before < 4000:
    problems.append('the viewer does not show the 3D text before the clicks (%s orange pixels)' % before)
if final is None or final < 4000:
    problems.append('the viewer does not show the 3D text at the end (%s orange pixels)' % final)
if problems:
    print('SUMMARY FAIL: ' + '; '.join(problems))
    sys.exit(1)
print('SUMMARY PASS')
PY
RC=$?
echo "dialogs dismissed by the test:"
sort "$OUT/dialogs.log" 2> /dev/null | uniq -c | head -n 10
if [ "$RC" -eq 0 ]; then
    echo "PASS: the Advanced 3D viewer renders a 1080p scene and survives the Draft 3D clicks (files in $OUT)"
else
    echo "FAIL: the Advanced 3D viewer test failed (files in $OUT)"
fi
exit "$RC"
