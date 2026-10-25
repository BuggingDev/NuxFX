#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Measures RAM preview. Starts After Effects with a temporary startup script that builds a
# 10 s comp with a moving, rotating layer and opens it. A sampler then takes a screenshot of
# the Xvfb screen about three times a second, presses the preview key (space) in the viewer and
# follows the picture: the position of the orange layer in the viewer is the comp time that is
# on screen, and the timeline shows the rest: the green cache bar, the blue current-time
# indicator and a red needle. During a preview After Effects does not move the blue indicator
# (comp.time stays at the start too); its player takes over the time needle and a thin red line
# runs along the ruler instead, which is removed when the preview stops. So the red needle is
# what has to follow the picture. The screen is the measurement. The viewer is located from
# the comp background, so the window layout does not matter.
# Reports the comp time reached, the playback speed (comp seconds per second of wall time) and
# how far the red needle moves and how closely it follows the picture. The preview loops: the
# first pass can wait for the renderer, a repeat plays from the RAM cache and shows the speed of
# the display path, which is the one that counts when the follow time is long enough for a
# repeat. Passes if the viewer reaches 9 s of the 10 s comp, the speed is at least
# AEGNUX_RP_MIN_SPEED (real time is 1.0) and the needle follows the picture.
#
# Knobs (all optional):
#   AEGNUX_RP_KEY       key that starts the preview (default space)
#   AEGNUX_RP_SECONDS   how long to follow the preview after the key (default 40)
#   AEGNUX_RP_MIN_SPEED lowest accepted playback speed (default 0.8)
#   AEGNUX_RP_NEEDLE_TOL largest accepted mean distance between the red needle and the picture,
#                       in seconds of comp time (default 0.6)
#   AEGNUX_RP_CYCLES    N > 0: start and stop the preview N times instead of measuring the speed (a cycle
#                       passes if the preview starts and the key that stops it removes the needle and moves
#                       the blue playhead to the stop frame); tests/run_ae_ram_preview_cycles_test.sh runs 3
#   AEGNUX_TEST_AUDIO   audio output of After Effects: auto (default; what launch_ae.sh does, see
#                       aegnux_audio_plan in scripts/common.sh), host (the machine's sound server as it is, no
#                       silent stream), null (a silent PulseAudio server of its own, scripts/null_audio.sh) or
#                       none (no audio device). RAM preview works with no audio device and with a sound server
#                       that works. The sound server of the Direct3D 12 route breaks it unless a silent stream keeps its output awake
#                       (scripts/sound_keepalive.sh): After Effects' audio thread hangs, it is ended by force
#                       when a preview stops (after a second) and the next preview does not start. With host
#                       on that server tests/run_ae_ram_preview_cycles_test.sh fails.
#   AEGNUX_RP_ENV       extra environment for Wine, e.g. "WINEESYNC=0 PULSE_LATENCY_MSEC=60"
#   AEGNUX_RP_REG       registry values to set first, ';'-separated "KEY|NAME|DATA|TYPE"
#   AEGNUX_RP_WINEDEBUG WINEDEBUG for this run
#   AEGNUX_RP_PRESSES   how many times the key is pressed, 20 s apart (default 1)
#   AEGNUX_RP_FX        match name of the effect on the moving layer (default
#                       "ADBE Gaussian Blur 2"; empty = no effect)
#   AEGNUX_REP_MOVSB=1  (set it in the environment of this script) turns off the glibc setting that
#                       keeps memcpy off "rep movsb" (see scripts/common.sh): the preview then
#                       plays at about a fifth of real time on the Direct3D 12 route
#   AEGNUX_RP_COMP      size and length of the comp, "WIDTHxHEIGHTxSECONDS" (default 1280x720x10)
#   AEGNUX_RP_CACHE_FIRST=1  sets "Cache Before Playback" of the Space shortcut for this run: the preview then
#                       renders the whole range into RAM first and plays it afterwards, as the numpad-0 RAM
#                       preview of a default setup does (tests/run_ae_ram_preview_cached_test.sh)
#   AEGNUX_RP_MEMWATCH=1  every 2 s the memory use of After Effects and of Wine is logged (mem.txt), and After
#                       Effects is stopped when the machine has less than AEGNUX_RP_MIN_AVAILABLE_MB (default
#                       2500) of available memory (tests/run_ae_ram_preview_heavy_test.sh)
#   AEGNUX_TEST_LOGDIR  keep the Wine stdout/stderr, the samples and the last screenshot there
# Exit status 6: After Effects ended during the test (it crashed or was closed); 7: the memory watchdog stopped it.
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
RP_NEEDLE_TOL="${AEGNUX_RP_NEEDLE_TOL:-0.6}"
RP_CYCLES="${AEGNUX_RP_CYCLES:-0}"
DELAY="${AEGNUX_RP_DELAY:-40}"
RP_FX="${AEGNUX_RP_FX-ADBE Gaussian Blur 2}"
RP_MIN_AVAILABLE_MB="${AEGNUX_RP_MIN_AVAILABLE_MB:-2500}"
IFS=x read -r CW CH CL <<< "${AEGNUX_RP_COMP:-1280x720x10}"
case "$CW$CH$CL" in
    ''|*[!0-9]*) echo "FAIL: AEGNUX_RP_COMP must look like 1280x720x10 (width x height x seconds)"; exit 1 ;;
esac

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
        cp "$WORK/out.log" "$WORK/err.log" "$WORK/samples.txt" "$WORK/last.ppm" "$WORK/mem.txt" "$AEGNUX_TEST_LOGDIR/" 2> /dev/null
    fi
    rm -f "$STARTUP" "$JSX"
    "$S/stop_ae.sh" > /dev/null 2>&1
    cache_first_restore
    aegnux_test_audio_down
    kill "$XVFB_PID" 2> /dev/null
    rm -rf "$WORK"
}

# AEGNUX_RP_CACHE_FIRST=1: "Cache Before Playback" of the Space shortcut is switched on in every preferences file of
# the prefix for this run, and put back as it was (or to AE's default, 0) afterwards.
CBP_SECTION="Unified Preview Options Spacebar"
CBP_KEY="Cache Before Playback"
CBP_SAVED=""
cache_first_set() {
    local d f n=0
    CBP_SAVED="$WORK/cbp_saved"
    : > "$CBP_SAVED"
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        for f in "$d"/Adobe\ After\ Effects\ *\ Prefs.txt; do
            [ -f "$f" ] || continue
            printf '%s\t%s\n' "$f" "$(aegnux_get_pref "$f" "$CBP_SECTION" "$CBP_KEY")" >> "$CBP_SAVED"
            aegnux_set_pref "$f" "$CBP_SECTION" "$CBP_KEY" '"1"'
            n=$((n + 1))
        done
    done < <(aegnux_ae_pref_dirs)
    [ "$n" -gt 0 ] || echo "note: no After Effects preferences file in the prefix yet, so Cache Before Playback keeps its default"
}
cache_first_restore() {
    local f old
    [ -n "$CBP_SAVED" ] && [ -f "$CBP_SAVED" ] || return 0
    while IFS=$'\t' read -r f old; do
        [ -f "$f" ] && aegnux_set_pref "$f" "$CBP_SECTION" "$CBP_KEY" "${old:-\"0\"}"
    done < "$CBP_SAVED"
}
trap cleanup EXIT
# After Effects needs a working audio output for RAM preview (AEGNUX_TEST_AUDIO, see the top).
aegnux_test_audio_up

# The layer crosses the comp from 5/32 to 27/32 of its width in CL seconds and turns twice (1280x720x10: 200 to
# 1080 of 1280 px, 720 degrees); the sampler turns its position on screen into a comp time with the same numbers.
cat > "$JSX" << EOF
// ExtendScript is ECMAScript 3 (no reserved words such as "final").
var comp = app.project.items.addComp("aegnux ram preview", $CW, $CH, 1.0, $CL, 30);
var bg = comp.layers.addSolid([0.1, 0.1, 0.4], "bg", $CW, $CH, 1.0);
var box = comp.layers.addSolid([1, 0.5, 0], "box", $((CH * 300 / 720)), $((CH * 300 / 720)), 1.0);
var tr = box.property("ADBE Transform Group");
tr.property("ADBE Position").setValueAtTime(0, [$((CW * 5 / 32)), $((CH / 2))]);
tr.property("ADBE Position").setValueAtTime($CL, [$((CW * 27 / 32)), $((CH / 2))]);
tr.property("ADBE Rotate Z").setValueAtTime(0, 0);
tr.property("ADBE Rotate Z").setValueAtTime($CL, $((CL * 72)));
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
min_speed, needle_tol, cycles = float(sys.argv[7]), float(sys.argv[8]), int(sys.argv[9])
COMP_W, LENGTH = float(sys.argv[10]), float(sys.argv[11])   # comp width in px, comp length in s
ppm = os.path.join(outdir, 'last.ppm')
W, H = 1920, 1080
BG = bytes((26, 26, 102))  # the "bg" solid of the comp, [0.1, 0.1, 0.4]
POS0, POS1 = COMP_W * 5 / 32, COMP_W * 27 / 32   # the orange layer moves from POS0 to POS1 in LENGTH s


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
    # the current-time indicator: a 1 px blue line (45,140,235) in the empty part of the timeline, row 950
    for x in range(300, 1900):
        r, g, b = px(pix, x, 950)
        if abs(r - 45) < 25 and abs(g - 140) < 30 and abs(b - 235) < 25:
            return x
    return -1


def needle(pix):
    # the preview needle: a 1 px red line (252,0,0) in the same row; -1 when there is none
    for x in range(300, 1900):
        r, g, b = px(pix, x, 950)
        if r >= 235 and g <= 30 and b <= 30:
            return x
    return -1


def green_cols(pix):
    # columns of the cache bar (16,192,32) above the layer bars
    cols = set()
    for y in range(822, 852, 2):
        for x in range(300, 1900):
            r, g, b = px(pix, x, y)
            if abs(r - 16) < 20 and abs(g - 192) < 30 and abs(b - 32) < 20:
                cols.add(x)
    return cols


def green(pix):
    return len(green_cols(pix))


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

if cycles:
    # Start and stop the preview `cycles` times. A cycle passes if the preview starts (the red needle shows and
    # the picture moves) and, after the key that stops it, the needle is gone and the blue playhead has jumped to
    # the frame where the preview stopped. Home takes the playhead back to the start before the next cycle.
    all_ok = True
    for i in range(cycles):
        if i == 0:
            subprocess.run(['xdotool', 'mousemove', '960', '420', 'click', '1'], stderr=subprocess.DEVNULL)
            time.sleep(0.5)
        else:
            subprocess.run(['xdotool', 'key', 'Home'], stderr=subprocess.DEVNULL)
            time.sleep(1.5)
        t_key = time.time()
        subprocess.run(['xdotool', 'key', key], stderr=subprocess.DEVNULL)
        log('%.2f cycle %d start key' % (t_key - start, i + 1))
        play = []
        while time.time() - t_key < 7.0:
            pix = shot()
            play.append((needle(pix), comp_time(pix)))
            time.sleep(0.1)
        seen = sum(1 for n, v in play if n > 0)
        reach = max([v for n, v in play] or [0.0])
        started = seen >= 3 and reach >= 2.0
        t_stop = time.time()
        subprocess.run(['xdotool', 'key', key], stderr=subprocess.DEVNULL)
        log('%.2f cycle %d stop key' % (t_stop - start, i + 1))
        after = []
        while time.time() - t_stop < 5.0:
            pix = shot()
            after.append((time.time() - t_stop, needle(pix), cti(pix)))
            time.sleep(0.1)
        gone = next((d for d, n, c in after if n < 0), None)
        end_x = after[-1][2] if after else -1
        stopped = gone is not None and end_x > x0 + 20
        print('cycle %d: %s (red needle in %d of %d samples, picture reached %.1f s); %s (needle gone %s, playhead at x=%d, start x=%d)' % (
            i + 1, 'started' if started else 'DID NOT START', seen, len(play), reach,
            'stopped' if stopped else 'DID NOT STOP', ('after %.1f s' % gone) if gone is not None else 'never', end_x, x0))
        all_ok = all_ok and started and stopped
    sys.exit(0 if all_ok else 5)

xs = []
spans = []
next_press = 0
pressed = 0
key_at = -1.0
while time.time() - start < seconds + 20 * (presses - 1):
    now = time.time() - start
    if pressed < presses and now >= next_press:
        # The first press clicks the viewer to give it the keyboard focus. Later presses only send the key: a
        # mouse click stops a running preview by itself, and the key would then start a new one.
        if pressed == 0:
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
    gc = green_cols(pix)
    gr = len(gc)
    if gc:
        spans.append((min(gc), max(gc)))
    t = comp_time(pix)
    nd = needle(pix)
    log('%.2f cti=%d green=%d viewer=%.2f needle=%d' % (w, x, gr, t, nd))
    xs.append((w, x, gr, t, nd))
    time.sleep(0.1)

tview = max([t for w, x, g, t, n in xs] or [0.0])
moved = max([x for w, x, g, t, n in xs] or [x0]) - x0
cache = max([g for w, x, g, t, n in xs] or [0])
# the preview loops: a pass ends where the comp time on screen drops back
passes = [[]]
top = 0.0
for w, x, g, t, n in xs:
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
    pts = [(w, t) for w, t in pts if 0.03 * LENGTH <= t <= LENGTH - 0.5 and w >= key_at]
    if len(pts) < 5:
        return 0.0
    mw = sum(w for w, t in pts) / len(pts)
    mt = sum(t for w, t in pts) / len(pts)
    den = sum((w - mw) ** 2 for w, t in pts)
    return sum((w - mw) * (t - mt) for w, t in pts) / den if den else 0.0


# The first pass can wait for the renderer. A repeat plays from the RAM cache, so it shows the
# speed of the display path. The screenshots that measure the speed come at uneven intervals (a busy
# display makes some of them take seconds), so the better of the two is taken: a preview that is slow
# is slow in both.
speed_first = slope(first)
speed_cached = slope(passes[1]) if len(passes) > 1 else 0.0
speed = max(speed_first, speed_cached)
# The red needle: its position along the ruler gives a comp time, (x - x0) / span * LENGTH, where x0 is the
# blue indicator (time 0) and span the width of the whole comp on the ruler (the cache bar at the end).
span = max([hi for lo, hi in spans] or [0]) - x0
if span < 300:
    span = 990
nds = [(w, n, t) for w, x, g, t, n in xs if n > 0 and w >= key_at]
needle_moved = (max(n for w, n, t in nds) - min(n for w, n, t in nds)) if nds else 0
errs = sorted(abs((n - x0) / float(span) * LENGTH - t) for w, n, t in nds if 0.3 <= t <= LENGTH - 0.3)
err_mean = sum(errs) / len(errs) if errs else -1.0
needle_ok = needle_moved >= 0.5 * span and len(errs) >= 20 and 0 <= err_mean <= needle_tol
print('timeline: the blue playhead stays at x=%d (moved %d px; the player hands it to a red needle), the cache bar spans %d px' % (x0, moved, cache))
print('timeline: the red preview needle moved %d px of %d (the whole comp) and is %.2f s from the picture on average (%d samples)' % (
    needle_moved, span, err_mean, len(errs)))
print('viewer: comp time on screen max %.2f s of %.0f, first pass reached %.2f s at %.1f s after the key' % (tview, LENGTH, first_top, t_at - key_at))
print('playback speed: %.2fx real time (first pass %.2fx, repeat from the cache %s)' % (
    speed, speed_first, '%.2fx' % speed_cached if speed_cached > 0 else 'not reached'))
sec = []
for k in range(0, int(seconds) + 1, 2):
    near = [t for w, x, g, t, n in xs if w >= key_at + k][:1]
    sec.append('%.1f' % near[0] if near and near[0] >= 0 else '-')
print('viewer time every 2 s: ' + ' '.join(sec))
if tview < 0.9 * LENGTH:
    sys.exit(1)
if speed < min_speed:
    sys.exit(3)
sys.exit(0 if needle_ok else 4)
PY

"$S/stop_ae.sh" > /dev/null 2>&1
"$S/clear_crash_state.sh" > /dev/null
AEGNUX_COACHMARKS=0 "$S/ae_prefs.sh" > /dev/null
[ "${AEGNUX_RP_CACHE_FIRST:-0}" = 1 ] && cache_first_set
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
python3 -I "$WORK/sampler.py" "$WORK/xcap" "$ROOT" "$WORK" "$RP_SECONDS" "$RP_KEY" "$RP_PRESSES" "$RP_MIN_SPEED" "$RP_NEEDLE_TOL" "$RP_CYCLES" "$CW" "$CL" &
SAMPLER=$!
# While the sampler follows the screen: is After Effects still there (a crash ends the process), and, with
# AEGNUX_RP_MEMWATCH=1, how much memory do After Effects and Wine hold and does the machine keep some free.
SEEN_AE=0
END_REASON=""
PEAK_RSS=0
MIN_AVAIL=999999
[ "${AEGNUX_RP_MEMWATCH:-0}" = 1 ] && echo "t_s memavail_mb rss_mb maps_main" > "$WORK/mem.txt"
T_START=$(date +%s)
while kill -0 "$SAMPLER" 2> /dev/null; do
    sleep 2
    if [ -n "$(aegnux_prefix_pids 'AfterFX[.]exe')" ]; then
        SEEN_AE=1
    elif [ "$SEEN_AE" = 1 ]; then
        END_REASON=gone
        kill "$SAMPLER" 2> /dev/null
        break
    fi
    if [ "${AEGNUX_RP_MEMWATCH:-0}" = 1 ]; then
        AVAIL=$(awk '/MemAvailable/{print int($2 / 1024)}' /proc/meminfo)
        RSS=0
        MAPS=0
        for pid in $(aegnux_prefix_pids '.'); do
            r=$(awk '/VmRSS/{print int($2 / 1024)}' "/proc/$pid/status" 2> /dev/null)
            [ -n "$r" ] && RSS=$((RSS + r))
            m=$(wc -l < "/proc/$pid/maps" 2> /dev/null)
            [ -n "$m" ] && [ "$m" -gt "$MAPS" ] && MAPS=$m
        done
        echo "$(($(date +%s) - T_START)) $AVAIL $RSS $MAPS" >> "$WORK/mem.txt"
        [ "$RSS" -gt "$PEAK_RSS" ] && PEAK_RSS=$RSS
        [ "$AVAIL" -lt "$MIN_AVAIL" ] && MIN_AVAIL=$AVAIL
        if [ "$AVAIL" -lt "$RP_MIN_AVAILABLE_MB" ]; then
            END_REASON=memory
            "$S/stop_ae.sh" > /dev/null 2>&1
            kill "$SAMPLER" 2> /dev/null
            break
        fi
    fi
done
wait "$SAMPLER" 2> /dev/null
RC=$?
[ "$END_REASON" = gone ] && RC=6
[ "$END_REASON" = memory ] && RC=7
if [ "${AEGNUX_RP_MEMWATCH:-0}" = 1 ]; then
    echo "memory: After Effects and Wine held at most $PEAK_RSS MB, the machine had at least $MIN_AVAIL MB available (of $(awk '/MemTotal/{print int($2 / 1024)}' /proc/meminfo) MB); mem.txt has the log"
fi
case "$RC" in
    0) if [ "$RP_CYCLES" -gt 0 ]; then
           echo "PASS: the RAM preview started and stopped $RP_CYCLES times"
       else
           echo "PASS: the RAM preview plays to the end of the comp at the expected speed and the preview needle follows the picture"
       fi ;;
    5) echo "FAIL: a RAM preview did not start or did not stop cleanly. A sound server that stalls makes After Effects end its audio thread by force, and the next preview does not start: scripts/doctor.sh (Audio), tests/run_pulse_resume_test.sh, AEGNUX_TEST_AUDIO=none shows whether audio is the cause" ;;
    1) echo "FAIL: the RAM preview stopped before the end of the comp" ;;
    3) echo "FAIL: the RAM preview plays slower than $RP_MIN_SPEED x real time" ;;
    4) echo "FAIL: the red preview needle of the timeline does not follow the picture (more than $RP_NEEDLE_TOL s apart, or it hardly moves)" ;;
    6) echo "FAIL: After Effects ended during the test (a crash, or somebody closed it); the Wine log is in AEGNUX_TEST_LOGDIR" ;;
    7) echo "FAIL: the machine ran below $RP_MIN_AVAILABLE_MB MB of available memory, After Effects was stopped" ;;
    *) echo "FAIL: no measurement (the comp never appeared)" ;;
esac
exit "$RC"
