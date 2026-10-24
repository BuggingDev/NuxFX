#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Measures RAM preview. Starts After Effects with a temporary startup script that builds a
# 10 s comp with a moving, rotating layer and opens it. A sampler then takes a screenshot of
# the Xvfb screen about three times a second, presses the preview key (space) in the viewer and
# follows the picture: the position of the orange layer in the viewer is the comp time that is
# on screen, and the blue playhead and the green cache bar of the timeline show the rest. A
# script cannot read the time of a running preview (comp.time stays at the start), so the
# screen is the measurement. The viewer is located from the comp background, so the window
# layout does not matter.
# Reports the comp time reached, the playback speed (comp seconds per second of wall time) and
# how far the playhead moves. The preview loops: the first pass can wait for the renderer, a
# repeat plays from the RAM cache and shows the speed of the display path, which is the one
# that counts when the follow time is long enough for a repeat. Passes if the viewer reaches 9 s
# of the 10 s comp and the speed is at least AEGNUX_RP_MIN_SPEED (real time is 1.0).
#
# Knobs (all optional):
#   AEGNUX_RP_KEY       key that starts the preview (default space)
#   AEGNUX_RP_SECONDS   how long to follow the preview after the key (default 40)
#   AEGNUX_RP_MIN_SPEED lowest accepted playback speed (default 0.8)
#   AEGNUX_RP_ENV       extra environment for Wine, e.g. "WINEESYNC=0 PULSE_LATENCY_MSEC=60"
#   AEGNUX_RP_REG       registry values to set first, ';'-separated "KEY|NAME|DATA|TYPE"
#   AEGNUX_RP_WINEDEBUG WINEDEBUG for this run
#   AEGNUX_RP_PRESSES   how many times the key is pressed, 20 s apart (default 1)
#   AEGNUX_RP_FX        match name of the effect on the moving layer (default
#                       "ADBE Gaussian Blur 2"; empty = no effect)
#   AEGNUX_REP_MOVSB=1  (set it in the environment of this script) turns off the glibc setting that
#                       keeps memcpy off "rep movsb" (see scripts/common.sh): the preview then
#                       plays at about a fifth of real time on the Direct3D 12 route
#   AEGNUX_TEST_LOGDIR  keep the Wine stdout/stderr, the samples and the last screenshot there
# Needs a 1920x1080 Xvfb display (the test creates it). Same prerequisites and Xvfb handling
# as tests/run_ae_viewer_test.sh. Any running After Effects of this prefix is stopped.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S="$HERE/../scripts"
. "$S/common.sh"
RP_KEY="${AEGNUX_RP_KEY:-space}"
RP_SECONDS="${AEGNUX_RP_SECONDS:-40}"
RP_PRESSES="${AEGNUX_RP_PRESSES:-1}"
RP_MIN_SPEED="${AEGNUX_RP_MIN_SPEED:-0.8}"
DELAY="${AEGNUX_RP_DELAY:-40}"
RP_FX="${AEGNUX_RP_FX-ADBE Gaussian Blur 2}"

for t in xdotool xwininfo python3 gcc; do
    if ! command -v "$t" > /dev/null; then
        echo "FAIL: $t not installed ($(aegnux_pkg_hint xdotool x11-utils python3 gcc libx11-dev))"
        exit 1
    fi
done
WORK=$(mktemp -d) || exit 1
gcc -O1 -o "$WORK/xcap" "$S/tools/xcap.c" -lX11 || exit 1

if ! { [ "${AEGNUX_TEST_XVFB:-1}" = 1 ] && command -v Xvfb > /dev/null; }; then
    echo "FAIL: this test needs Xvfb (it follows the screen)"
    exit 1
fi
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
JSX="$USERDIR/aegnux_rp_test.jsx"
STARTUP="$AE_DIR/Scripts/Startup/zz_aegnux_rp_test.jsx"
DISMISS_PID=""
cleanup() {
    [ -n "$DISMISS_PID" ] && kill "$DISMISS_PID" 2> /dev/null
    if [ -n "${AEGNUX_TEST_LOGDIR:-}" ]; then
        mkdir -p "$AEGNUX_TEST_LOGDIR"
        cp "$WORK/out.log" "$WORK/err.log" "$WORK/samples.txt" "$WORK/last.ppm" "$AEGNUX_TEST_LOGDIR/" 2> /dev/null
    fi
    rm -f "$STARTUP" "$JSX"
    "$S/stop_ae.sh" > /dev/null 2>&1
    kill "$XVFB_PID" 2> /dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$JSX" << 'EOF'
// ExtendScript is ECMAScript 3 (no reserved words such as "final").
var comp = app.project.items.addComp("aegnux ram preview", 1280, 720, 1.0, 10, 30);
var bg = comp.layers.addSolid([0.1, 0.1, 0.4], "bg", 1280, 720, 1.0);
var box = comp.layers.addSolid([1, 0.5, 0], "box", 300, 300, 1.0);
var tr = box.property("ADBE Transform Group");
tr.property("ADBE Position").setValueAtTime(0, [200, 360]);
tr.property("ADBE Position").setValueAtTime(10, [1080, 360]);
tr.property("ADBE Rotate Z").setValueAtTime(0, 0);
tr.property("ADBE Rotate Z").setValueAtTime(10, 720);
box.property("ADBE Effect Parade").addProperty("ADBE Gaussian Blur 2");
comp.openInViewer();
comp.time = 0;
EOF
if [ -n "$RP_FX" ]; then
    sed -i "s/ADBE Gaussian Blur 2/$RP_FX/" "$JSX"
else
    sed -i '/addProperty/d' "$JSX"
fi
printf 'app.scheduleTask("$.evalFile(new File(\x27C:/users/%s/aegnux_rp_test.jsx\x27))", %s, false);\n' "$U" "$((DELAY * 1000))" > "$STARTUP"

cat > "$WORK/sampler.py" << 'PY'
import os, subprocess, sys, time

xcap, root, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
seconds, key, presses = float(sys.argv[4]), sys.argv[5], int(sys.argv[6])
min_speed = float(sys.argv[7])
ppm = os.path.join(outdir, 'last.ppm')
W, H = 1920, 1080
BG = bytes((26, 26, 102))  # the "bg" solid of the comp, [0.1, 0.1, 0.4]
COMP_W = 1280.0            # comp width in px
POS0, POS1, LENGTH = 200.0, 1080.0, 10.0  # the orange layer moves from POS0 to POS1 in LENGTH s


def shot():
    subprocess.run([xcap, root, ppm], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    d = open(ppm, 'rb').read()
    return d[len(d) - W * H * 3:]


def px(pix, x, y):
    i = (y * W + x) * 3
    return pix[i], pix[i + 1], pix[i + 2]


def find_aligned(row, pat, last=False):
    # index (in pixels) of the first or last pixel of a row of 3-byte pixels that equals pat
    i = row.rfind(pat) if last else row.find(pat)
    while i >= 0 and i % 3:
        i = row.rfind(pat, 0, i + 2) if last else row.find(pat, i + 1)
    return i // 3 if i >= 0 else -1


def frame(pix):
    # left and right edge of the comp in the viewer: the outermost "bg" pixels of a few rows
    left, right = W, -1
    for y in range(140, 735, 15):
        row = pix[(y * W + 330) * 3:(y * W + 1600) * 3]
        a = find_aligned(row, BG)
        if a >= 0:
            left = min(left, a + 330)
            right = max(right, find_aligned(row, BG, True) + 330)
    return (left, right) if right > left + 200 else None


def cti(pix):
    # the playhead: a 1 px blue line (45,140,235) in the empty part of the timeline, row 950
    for x in range(300, 1900):
        r, g, b = px(pix, x, 950)
        if abs(r - 45) < 25 and abs(g - 140) < 30 and abs(b - 235) < 25:
            return x
    return -1


def green(pix):
    # columns of the cache bar (16,192,32) above the layer bars
    cols = set()
    for y in range(822, 852, 2):
        for x in range(300, 1900):
            r, g, b = px(pix, x, y)
            if abs(r - 16) < 20 and abs(g - 192) < 30 and abs(b - 32) < 20:
                cols.add(x)
    return len(cols)


def comp_time(pix):
    # comp time on screen, from the centre of the orange layer (it rotates about its centre, so
    # the centre is the position): -1 if the viewer does not show the comp
    f = frame(pix)
    if not f:
        return -1.0
    sx = n = 0
    for y in range(140, 736, 4):
        base = (y * W + f[0]) * 3
        row = pix[base:base + (f[1] - f[0] + 1) * 3]
        for k, (r, g, b) in enumerate(zip(row[0::9], row[1::9], row[2::9])):
            if r > 200 and 90 < g < 175 and b < 70:
                sx += f[0] + 3 * k
                n += 1
    if n < 50:
        return -1.0
    pos = (sx / n - f[0]) * COMP_W / (f[1] - f[0] + 1)
    return max(0.0, (pos - POS0) / (POS1 - POS0) * LENGTH)


samples = open(os.path.join(outdir, 'samples.txt'), 'w')


def log(line):
    samples.write(line + '\n')
    samples.flush()


# 1. wait for the comp: the viewer shows the comp frame and the playhead is in the timeline
t0 = time.time()
x0 = -1
while time.time() - t0 < 200:
    pix = shot()
    x = cti(pix)
    if x > 0 and frame(pix):
        time.sleep(1)
        pix = shot()
        if cti(pix) == x and frame(pix):
            x0 = x
            break
    time.sleep(1)
if x0 < 0:
    print('NOCOMP')
    sys.exit(2)
time.sleep(5)
start = time.time()
log('0.00 comp ready cti=%d' % x0)
xs = []
next_press = 0
pressed = 0
key_at = -1.0
while time.time() - start < seconds + 20 * (presses - 1):
    now = time.time() - start
    if pressed < presses and now >= next_press:
        subprocess.run(['xdotool', 'mousemove', '960', '420', 'click', '1'], stderr=subprocess.DEVNULL)
        time.sleep(0.5)
        subprocess.run(['xdotool', 'key', key], stderr=subprocess.DEVNULL)
        pressed += 1
        next_press += 20
        if key_at < 0:
            key_at = time.time() - start
        log('%.2f key %d' % (time.time() - start, pressed))
    pix = shot()
    w = time.time() - start
    x = cti(pix)
    gr = green(pix)
    t = comp_time(pix)
    log('%.2f cti=%d green=%d viewer=%.2f' % (w, x, gr, t))
    xs.append((w, x, gr, t))
    time.sleep(0.1)

tview = max([t for w, x, g, t in xs] or [0.0])
moved = max([x for w, x, g, t in xs] or [x0]) - x0
cache = max([g for w, x, g, t in xs] or [0])
# the preview loops: a pass ends where the comp time on screen drops back
passes = [[]]
top = 0.0
for w, x, g, t in xs:
    if t < 0:
        continue
    if t < top - 1.0:
        passes.append([])
        top = t
    top = max(top, t)
    passes[-1].append((w, t))
first = passes[0]
first_top = max([t for w, t in first] or [0.0])
t_at = next((w for w, t in first if t >= first_top - 0.05), 0.0)


def slope(pts):
    # least-squares slope of the comp time on screen over the wall time, where the picture moves
    pts = [(w, t) for w, t in pts if 0.3 <= t <= 9.5 and w >= key_at]
    if len(pts) < 5:
        return 0.0
    mw = sum(w for w, t in pts) / len(pts)
    mt = sum(t for w, t in pts) / len(pts)
    den = sum((w - mw) ** 2 for w, t in pts)
    return sum((w - mw) * (t - mt) for w, t in pts) / den if den else 0.0


# The first pass can wait for the renderer. A repeat plays from the RAM cache, so it shows the
# speed of the display path.
speed_first = slope(first)
speed_cached = slope(passes[1]) if len(passes) > 1 else 0.0
speed = speed_cached if speed_cached > 0 else speed_first
print('timeline playhead: moved %d px, the cache bar spans %d px' % (moved, cache))
print('viewer: comp time on screen max %.2f s of %.0f, first pass reached %.2f s at %.1f s after the key' % (tview, LENGTH, first_top, t_at - key_at))
print('playback speed: %.2fx real time (first pass %.2fx, repeat from the cache %s)' % (
    speed, speed_first, '%.2fx' % speed_cached if speed_cached > 0 else 'not reached'))
sec = []
for k in range(0, int(seconds) + 1, 2):
    near = [t for w, x, g, t in xs if w >= key_at + k][:1]
    sec.append('%.1f' % near[0] if near and near[0] >= 0 else '-')
print('viewer time every 2 s: ' + ' '.join(sec))
if tview < 9.0:
    sys.exit(1)
sys.exit(0 if speed >= min_speed else 3)
PY

"$S/stop_ae.sh" > /dev/null 2>&1
"$S/clear_crash_state.sh" > /dev/null
AEGNUX_COACHMARKS=0 "$S/ae_prefs.sh" > /dev/null
aegnux_env
if [ -n "${AEGNUX_RP_REG:-}" ]; then
    OLDIFS=$IFS; IFS=';'
    for entry in $AEGNUX_RP_REG; do
        IFS='|' read -r key name data type <<< "$entry"
        wine reg add "$key" /v "$name" /d "$data" /t "${type:-REG_SZ}" /f > /dev/null 2>&1
    done
    IFS=$OLDIFS
    "$WINE_BIN_DIR/wineserver" -w > /dev/null 2>&1
fi
[ -n "${AEGNUX_RP_WINEDEBUG:-}" ] && export WINEDEBUG="$AEGNUX_RP_WINEDEBUG"
cd "$AE_DIR" || exit 1
# shellcheck disable=SC2086
env ${AEGNUX_RP_ENV:-} timeout $((DELAY + RP_SECONDS + 20 * RP_PRESSES + 300)) wine AfterFX.exe > "$WORK/out.log" 2> "$WORK/err.log" < /dev/null &
disown $!

# dismiss the dialogs the tests know about while the sampler runs
(
    while :; do
        sleep 4
        for X in $(xdotool search --onlyvisible --class afterfx 2> /dev/null); do
            case "$(xwininfo -id "$X" 2> /dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')" in
                430x211|494x200|494x111) xdotool key --window "$X" Return 2> /dev/null ;;
            esac
        done
        for X in $(xdotool search --onlyvisible --name "System Compatibility Report" 2> /dev/null); do
            xdotool mousemove --window "$X" 437 481 click 1 2> /dev/null
        done
    done
) &
DISMISS_PID=$!

ROOT=$(xwininfo -root | awk '/Window id:/{print $4}')
python3 -I "$WORK/sampler.py" "$WORK/xcap" "$ROOT" "$WORK" "$RP_SECONDS" "$RP_KEY" "$RP_PRESSES" "$RP_MIN_SPEED"
RC=$?
case "$RC" in
    0) echo "PASS: the RAM preview plays to the end of the comp at the expected speed" ;;
    1) echo "FAIL: the RAM preview stopped before the end of the comp" ;;
    3) echo "FAIL: the RAM preview plays slower than $RP_MIN_SPEED x real time" ;;
    *) echo "FAIL: no measurement (the comp never appeared)" ;;
esac
exit "$RC"
