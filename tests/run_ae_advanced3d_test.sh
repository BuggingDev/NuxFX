#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# End-to-end check of the Advanced 3D renderer (ADBE Calder). Starts After Effects with a
# temporary startup script that creates a comp, selects the Advanced 3D renderer, adds a red
# 3D solid tilted in space and saves frame 0 as a PNG. The script reports the renderer AE
# accepted in the name of the comp, inside a project it saves (scripts may not write files
# unless the user allows it in the AE preferences, so no file is written by the script).
# Passes if AE kept the Advanced 3D renderer and the PNG shows red pixels and no magenta
# (the colour of a failed Calder render).
#
# Needs the CUDA bridge (AEGNUX_DISABLE_CUDA=0). Same prerequisites and Xvfb handling as
# tests/run_ae_viewer_test.sh. Any running After Effects of this prefix is stopped.
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
if [ "${AEGNUX_DISABLE_CUDA:-0}" = 1 ]; then
    echo "FAIL: Advanced 3D needs the CUDA bridge (AEGNUX_DISABLE_CUDA is 1)"
    exit 1
fi
WORK=$(mktemp -d) || exit 1
gcc -O1 -o "$WORK/xcap" "$S/tools/xcap.c" -lX11 || exit 1

XVFB_PID=""
if [ "${AEGNUX_TEST_XVFB:-1}" = 1 ] && command -v Xvfb > /dev/null; then
    # All WSL2 distributions share one network namespace, so the abstract X sockets of other
    # distributions' servers count as taken too (/proc/net/unix lists them).
    N=99
    while [ -e "/tmp/.X$N-lock" ] || grep -q "@/tmp/.X11-unix/X$N\$" /proc/net/unix 2> /dev/null; do N=$((N - 1)); done
    Xvfb ":$N" -screen 0 1920x1080x24 -nolisten tcp > /dev/null 2>&1 &
    XVFB_PID=$!
    export DISPLAY=":$N"
    for _ in $(seq 1 50); do xwininfo -root > /dev/null 2>&1 && break; sleep 0.2; done
    xwininfo -root > /dev/null 2>&1 || { echo "FAIL: Xvfb did not start on $DISPLAY"; kill "$XVFB_PID" 2> /dev/null; exit 1; }
else
    echo "note: using DISPLAY=${DISPLAY:-}; do not touch the After Effects window during the test"
fi
# Wine uses its Wayland driver when WAYLAND_DISPLAY is set, and the windows would not appear
# on the private X display.
[ -n "$XVFB_PID" ] && unset WAYLAND_DISPLAY

U=$(aegnux_win_user)
USERDIR="$WINEPREFIX/drive_c/users/$U"
JSX="$USERDIR/aegnux_a3d_test.jsx"
PROJECT="$USERDIR/aegnux_a3d_result.aep"
FRAME="$USERDIR/aegnux_a3d_frame.png"
STARTUP="$AE_DIR/Scripts/Startup/zz_aegnux_a3d_test.jsx"
cleanup() {
    if [ -n "${AEGNUX_TEST_LOGDIR:-}" ]; then
        mkdir -p "$AEGNUX_TEST_LOGDIR"
        cp "$WORK/out.log" "$WORK/err.log" "$AEGNUX_TEST_LOGDIR/" 2> /dev/null
    fi
    rm -f "$STARTUP" "$JSX" "$PROJECT" "$FRAME"
    "$S/stop_ae.sh" > /dev/null 2>&1
    if [ -n "$XVFB_PID" ]; then kill "$XVFB_PID" 2> /dev/null; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
rm -f "$PROJECT" "$FRAME"

cat > "$JSX" << EOF
var frame = new File("C:/users/$U/aegnux_a3d_frame.png");
var project = new File("C:/users/$U/aegnux_a3d_result.aep");
EOF
cat >> "$JSX" << 'EOF'
function clean(s) { return String(s).replace(/[^A-Za-z0-9]/g, "_"); }
var comp = app.project.items.addComp("aegnux advanced 3d test", 640, 480, 1.0, 5, 30);
try { comp.renderer = "ADBE Calder"; } catch (e) { }
var solid = comp.layers.addSolid([1, 0, 0], "Red Solid", 400, 300, 1.0);
solid.threeDLayer = true;
solid.property("ADBE Transform Group").property("ADBE Orientation").setValue([30, 20, 0]);
// The first Advanced 3D render compiles shaders and can fail while After Effects is still
// starting, so it is tried again a few times.
var rendered = false, err = "";
for (var attempt = 0; attempt < 10 && !rendered; attempt++) {
    try { comp.saveFrameToPng(0, frame); rendered = frame.exists; } catch (e) { err = clean(e).substring(0, 60); }
    if (!rendered) $.sleep(3000);
}
// Which GPU acceleration the project uses (CUDA is expected with the CUDA bridge).
var gpu = "unknown";
try {
    var gpuNames = ["CUDA", "METAL", "OPENCL", "SOFTWARE", "VULKAN"];
    for (var gi = 0; gi < gpuNames.length; gi++) {
        if (typeof GpuAccelType !== "undefined" && typeof GpuAccelType[gpuNames[gi]] !== "undefined" &&
            app.project.gpuAccelType == GpuAccelType[gpuNames[gi]]) gpu = gpuNames[gi];
    }
} catch (e) { gpu = "err"; }
comp.name = "RESULT_renderer_" + clean(comp.renderer) + "_frame_" + rendered + "_gpu_" + gpu + "_err_" + err;
app.project.save(project);
EOF
printf 'app.scheduleTask("$.evalFile(new File(\x27C:/users/%s/aegnux_a3d_test.jsx\x27))", %s, false);\n' "$U" "$(( ${AEGNUX_TEST_DELAY:-30} * 1000 ))" > "$STARTUP"

"$S/stop_ae.sh" > /dev/null 2>&1
"$S/clear_crash_state.sh" > /dev/null
AEGNUX_COACHMARKS=0 "$S/ae_prefs.sh" > /dev/null
aegnux_env
cd "$AE_DIR" || exit 1
timeout $((WAIT + 30)) wine AfterFX.exe > "$WORK/out.log" 2> "$WORK/err.log" < /dev/null &
disown $!

T=0
while [ "$T" -lt "$WAIT" ]; do
    sleep 5
    T=$((T + 5))
    [ -s "$PROJECT" ] && break
    # 494x200: "Crash Repair Options" (Continue is the default button).
    # 494x111: error box (OK).
    for X in $(xdotool search --onlyvisible --class afterfx 2> /dev/null); do
        case "$(xwininfo -id "$X" 2> /dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')" in
            494x200|494x111) xdotool key --window "$X" Return 2> /dev/null ;;
        esac
    done
    # Adobe's System Compatibility Report waits for a click on "Continue with known issues".
    for X in $(xdotool search --onlyvisible --name "System Compatibility Report" 2> /dev/null); do
        xdotool mousemove --window "$X" 437 481 click 1 2> /dev/null
    done
done
sleep 3

if [ -n "$XVFB_PID" ]; then
    TARGET=$(xwininfo -root | awk '/Window id:/{print $4}')
else
    TARGET=$(xdotool search --name "Adobe After Effects" 2> /dev/null | head -n 1)
fi
mkdir -p "$AEGNUX_TEST_DIR"
if [ -n "$TARGET" ] && "$WORK/xcap" "$TARGET" "$WORK/screen.ppm" > /dev/null; then
    cp "$WORK/screen.ppm" "$AEGNUX_TEST_DIR/ae_advanced3d_test.ppm"
fi
[ -f "$FRAME" ] && cp "$FRAME" "$AEGNUX_TEST_DIR/ae_advanced3d_frame.png"

python3 -I - "$FRAME" "$PROJECT" << 'PY'
import os, re, struct, sys, zlib

def read_png(path):
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a PNG')
    pos, idat, ihdr = 8, b'', None
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b'IHDR':
            ihdr = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
        pos += 12 + n
    w, h, depth, ctype = ihdr[0], ihdr[1], ihdr[2], ihdr[3]
    if depth != 8 or ctype not in (2, 6):
        raise ValueError('unsupported PNG format %d/%d' % (depth, ctype))
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line)
        prev = line
    return w, h, bpp, rows

renderer = ''
gpu = 'unknown'
try:
    m = re.search(rb'RESULT_renderer_([A-Za-z0-9_]+?)_frame_(true|false)_gpu_([A-Za-z0-9]+)_err_([A-Za-z0-9_]*)', open(sys.argv[2], 'rb').read())
    if m:
        renderer = m.group(1).decode()
        gpu = m.group(3).decode()
        if m.group(4):
            print('script error: ' + m.group(4).decode())
except OSError:
    pass
accepted = renderer == 'ADBE_Calder'
# With the CUDA bridge installed the project has to use CUDA ("unknown": AE did not say).
if os.environ.get('AEGNUX_DISABLE_CUDA') != '1' and gpu not in ('CUDA', 'unknown'):
    print('GPU acceleration is %s, CUDA was expected' % gpu)
    accepted = False
red = magenta = 0
try:
    w, h, bpp, rows = read_png(sys.argv[1])
    for line in rows:
        for x in range(0, w * bpp, bpp):
            r, g, b = line[x], line[x + 1], line[x + 2]
            if bpp == 4 and line[x + 3] < 128:
                continue
            if r > 100 and g < 50 and b < 50:
                red += 1
            elif r > 200 and g < 60 and b > 200:
                magenta += 1
except (OSError, ValueError, zlib.error) as e:
    print('frame not readable:', e)
print('renderer %s, GPU acceleration %s, red pixels %d, magenta pixels %d' % (renderer or '(unknown)', gpu, red, magenta))
sys.exit(0 if accepted and red > 20000 and magenta < 2000 else 1)
PY
RC=$?
if [ "$RC" -eq 0 ]; then
    echo "PASS: the Advanced 3D renderer renders the 3D solid"
else
    echo "FAIL: Advanced 3D did not render (files in $AEGNUX_TEST_DIR)"
fi
exit "$RC"
