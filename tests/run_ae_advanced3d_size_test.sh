#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Resolution limit of the Advanced 3D renderer (ADBE Calder). The scene tests render 480x270 comps.
# This test starts After Effects once, builds the same small scene (an extruded 3D text, a wall, a
# camera, a point light; and a second variant with an Environment light that casts shadows) at several
# sizes, renders frame 0 of each to a PNG and checks the picture. Large frames make the renderer split
# them into tiles (After Effects logs "3D.Tiling ... Tile size Y"), which is the path that opens shared
# D3D11 textures with a keyed mutex.
#
# Knobs (all optional):
#   AEGNUX_A3D_SIZES      comma-separated WxH list (default 480x270,960x540,1280x720,1920x1080)
#   AEGNUX_A3D_VARIANTS   plain,shadow (default both)
#   AEGNUX_A3D_WINEDEBUG  WINEDEBUG for this run (default err+all,warn+vulkan,fixme+d3dkmt)
#   AEGNUX_TEST_DELAY     seconds after the start before the scenes are built (default 30)
#   AEGNUX_TEST_WAIT      seconds to wait for the results (default 600)
#   AEGNUX_TEST_LOGDIR    keep the Wine stdout/stderr and the dialog log there
# The pictures, the dialog log and the Wine lines about DXVK, d3dkmt or a crash go to
# $AEGNUX_TEST_DIR/advanced3d_size. Needs the CUDA bridge and a private Xvfb (AEGNUX_TEST_XVFB must
# stay 1). Any running After Effects of this prefix is stopped. Passes when every size renders a valid
# picture; a size that crashes After Effects fails the test and the sizes after it have no result.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S="$HERE/../scripts"
. "$S/common.sh"
WAIT="${AEGNUX_TEST_WAIT:-600}"
DELAY="${AEGNUX_TEST_DELAY:-30}"
SIZES=$(printf '%s' "${AEGNUX_A3D_SIZES:-480x270,960x540,1280x720,1920x1080}" | tr -cd '0-9x,')
VARIANTS=$(printf '%s' "${AEGNUX_A3D_VARIANTS:-plain,shadow}" | tr -cd 'a-z,')
OUT="$AEGNUX_TEST_DIR/advanced3d_size"

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
JSX="$USERDIR/aegnux_a3d_size_test.jsx"
PROJECT="$USERDIR/aegnux_a3d_size_result.aep"
SHOT="$USERDIR/aegnux_a3d_size_"
STARTUP="$AE_DIR/Scripts/Startup/zz_aegnux_a3d_size_test.jsx"
DISMISS_PID=""
cleanup() {
    [ -n "$DISMISS_PID" ] && kill "$DISMISS_PID" 2> /dev/null
    if [ -n "${AEGNUX_TEST_LOGDIR:-}" ]; then
        mkdir -p "$AEGNUX_TEST_LOGDIR"
        cp "$WORK/out.log" "$WORK/err.log" "$WORK/dialogs.log" "$WORK/windows.log" "$AEGNUX_TEST_LOGDIR/" 2> /dev/null
    fi
    rm -f "$STARTUP" "$JSX" "$PROJECT" "$SHOT"*.png
    "$S/stop_ae.sh" > /dev/null 2>&1
    kill "$XVFB_PID" 2> /dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
rm -f "$PROJECT" "$SHOT"*.png
mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT"/*.aep "$OUT"/*.log "$OUT"/*.txt "$OUT"/*.ppm

cat > "$JSX" << EOF
var SHOT = "C:/users/$U/aegnux_a3d_size_";
var PROJECT_PATH = "C:/users/$U/aegnux_a3d_size_result.aep";
var SIZES = "$SIZES".split(",");
var VARIANTS = ",$VARIANTS,";
EOF
cat >> "$JSX" << 'EOF'
// ExtendScript is ECMAScript 3: var only, no arrow functions, no ES5 array methods, no trailing commas.
function safe(s) {
    var t = String(s).replace(/[^A-Za-z0-9]/g, "_");
    while (t.indexOf("__") >= 0) { t = t.replace(/__/g, "_"); }
    return t.substring(0, 80);
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
function tryProp(p, v) { try { if (p) { p.setValue(v); return true; } } catch (e) { } return false; }

// The same scene at every size: all positions scale with the comp, so the picture is comparable.
function build(w, h, variant) {
    var k = w / 480;
    var comp = app.project.items.addComp("a3d " + w + "x" + h + " " + variant, w, h, 1.0, 5, 30);
    comp.renderer = "ADBE Calder";
    var wall = comp.layers.addSolid([0.7, 0.72, 0.78], "wall", w * 3, h * 3, 1.0);
    wall.threeDLayer = true;
    wall.property("ADBE Transform Group").property("ADBE Position").setValue([w / 2, h / 2, 300 * k]);
    tryProp(findProp(wall, "Accepts Shadows"), 1);
    tryProp(findProp(wall, "Casts Shadows"), 1);
    var tl = comp.layers.addText("SIZE");
    tl.threeDLayer = true;
    var doc = tl.property("ADBE Text Properties").property("ADBE Text Document");
    var td = doc.value;
    td.fontSize = 110 * k;
    td.fillColor = [0.93, 0.33, 0.12];
    td.applyFill = true;
    doc.setValue(td);
    tl.property("ADBE Transform Group").property("ADBE Position").setValue([w / 2 - 80 * k, h / 2 + 30 * k, 0]);
    tl.property("ADBE Transform Group").property("ADBE Orientation").setValue([10, -20, 0]);
    tryProp(findProp(tl, "Extrsn Depth"), 60 * k);
    tryProp(findProp(tl, "Accepts Shadows"), 1);
    tryProp(findProp(tl, "Casts Shadows"), 1); // 1 draws the layer and casts; 2 is "Only" (not drawn)
    var cam = comp.layers.addCamera("cam", [w / 2, h / 2]);
    cam.property("ADBE Transform Group").property("ADBE Position").setValue([w / 2, h / 2, -700 * k]);
    var lt = comp.layers.addLight("point", [w / 2, h / 2]);
    lt.lightType = LightType.POINT;
    lt.property("ADBE Transform Group").property("ADBE Position").setValue([w * 0.15, h * 0.15, -400 * k]);
    tryProp(findProp(lt, "Light Intensity"), 110);
    if (variant == "shadow") {
        var env = comp.layers.addLight("environment", [w / 2, h / 2]);
        env.lightType = LightType.ENVIRONMENT;
        tryProp(findProp(env, "Light Intensity"), 60);
        tryProp(findProp(env, "Casts Shadows"), 1);
    }
    return comp;
}

function renderPng(comp, tag) {
    var file = new File(SHOT + tag + ".png");
    var res = {ok: false, tries: 0, err: "", ms: 0};
    var t0 = new Date().getTime();
    for (var a = 0; a < 4 && !res.ok; a++) {
        res.tries++;
        try {
            comp.saveFrameToPng(0, file);
            res.ok = file.exists;
        } catch (e) { res.err = String(e); }
        if (!res.ok) { $.sleep(2000); }
    }
    res.ms = new Date().getTime() - t0;
    return res;
}

function record(tag, built, rend) {
    var c = app.project.items.addComp("A3DSZ__" + tag + "__built-" + built + "__rend-" + (rend.ok ? 1 : 0) +
        "__try-" + rend.tries + "__ms-" + rend.ms + "__err-" + (rend.err ? safe(rend.err) : "none") + "__end", 16, 16, 1.0, 1, 30);
    app.project.save(new File(PROJECT_PATH));
}

try {
    for (var i = 0; i < SIZES.length; i++) {
        var wh = SIZES[i].split("x");
        var w = parseInt(wh[0], 10);
        var h = parseInt(wh[1], 10);
        var vs = ["plain", "shadow"];
        for (var j = 0; j < vs.length; j++) {
            if (VARIANTS.indexOf("," + vs[j] + ",") < 0) { continue; }
            var tag = w + "x" + h + "_" + vs[j];
            var comp = null;
            var built = 0;
            try { comp = build(w, h, vs[j]); built = 1; } catch (e) { }
            var rend = {ok: false, tries: 0, err: "not rendered", ms: 0};
            if (built) { rend = renderPng(comp, tag); }
            record(tag, built, rend);
        }
    }
    app.project.items.addComp("A3DSZ__done", 16, 16, 1.0, 1, 30);
    app.project.save(new File(PROJECT_PATH));
} catch (e4) {
    app.project.items.addComp("A3DSZ__fatal__err-" + safe(e4), 16, 16, 1.0, 1, 30);
    app.project.save(new File(PROJECT_PATH));
}
EOF
printf 'app.scheduleTask("$.evalFile(new File(\x27C:/users/%s/aegnux_a3d_size_test.jsx\x27))", %s, false);\n' "$U" "$((DELAY * 1000))" > "$STARTUP"

"$S/stop_ae.sh" > /dev/null 2>&1
"$S/clear_crash_state.sh" > /dev/null
AEGNUX_COACHMARKS=0 "$S/ae_prefs.sh" > /dev/null
export WINEDEBUG="${AEGNUX_A3D_WINEDEBUG:-err+all,warn+vulkan,fixme+d3dkmt}"
aegnux_env
cd "$AE_DIR" || exit 1
timeout $((WAIT + 60)) wine AfterFX.exe > "$WORK/out.log" 2> "$WORK/err.log" < /dev/null &
disown $!

# Dialogs: 430x211 (Advanced 3D not supported), 494x200 (Crash Repair Options), 494x111 (error
# box), 494x141 (warning box) get Return. Every window size and title seen is logged.
(
    while :; do
        sleep 3
        for X in $(xdotool search --onlyvisible --class afterfx 2> /dev/null); do
            SZ=$(xwininfo -id "$X" 2> /dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')
            NAME=$(xdotool getwindowname "$X" 2> /dev/null | tr -d '\n')
            grep -qxF "$SZ $NAME" "$WORK/windows.log" 2> /dev/null || echo "$SZ $NAME" >> "$WORK/windows.log"
            case "$SZ" in
                430x211|494x200|494x111|494x141)
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

T=0
CRASH=""
while [ "$T" -lt "$WAIT" ]; do
    sleep 3
    T=$((T + 3))
    grep -q -a -E 'A3DSZ__(done|fatal)' "$PROJECT" 2> /dev/null && break
    if grep -q -a "Crash in progress\|Unhandled exception\|terminate called" "$WORK/err.log" "$WORK/out.log" "$WORK/dialogs.log" 2> /dev/null; then
        CRASH=1
    fi
    if [ "$T" -ge 30 ] && [ -z "$(aegnux_prefix_pids 'AfterFX[.]exe')" ]; then
        echo "note: After Effects exited before the sizes were done"
        break
    fi
    # A Crash in progress box is an AE error dialog (494x111); the dismisser answers it, and the
    # process ends soon after.
    if [ -n "$CRASH" ] && [ "$T" -ge 60 ]; then
        sleep 6
        break
    fi
done
sleep 2

for f in "$SHOT"*.png; do
    [ -f "$f" ] && cp "$f" "$OUT/$(basename "$f" | sed 's/^aegnux_a3d_size_//')"
done
kill "$DISMISS_PID" 2> /dev/null
DISMISS_PID=""
"$S/stop_ae.sh" > /dev/null 2>&1
[ -f "$PROJECT" ] && cp "$PROJECT" "$OUT/result.aep"
cp "$WORK/dialogs.log" "$WORK/windows.log" "$OUT/" 2> /dev/null
grep -a -i -E 'dxvk|d3dkmt|device lost|device_lost|vk_error|dzn|unhandled|page fault|c0000005|terminate called|DxvkError|OpenResource|semi-stub' "$WORK/err.log" | sed -E 's/0x[0-9a-f]+/0xN/g' | sort | uniq -c | sort -rn > "$OUT/wine_lines.txt" 2> /dev/null
grep -a -h -i -E 'crash in progress|3D[.]Tiling' "$WORK/out.log" "$WORK/err.log" "$WORK/dialogs.log" >> "$OUT/wine_lines.txt" 2> /dev/null
echo "wine err lines: $(grep -a -c '^err:' "$WORK/err.log" 2> /dev/null); OpenResourceFromNtHandle calls: $(grep -a -c 'OpenResourceFromNtHandle' "$WORK/err.log" 2> /dev/null); DxvkError: $(grep -a -c 'DxvkError' "$WORK/err.log" 2> /dev/null)"

python3 -I - "$OUT" "$PROJECT" "$SIZES" "$VARIANTS" << 'PY'
import os, re, struct, sys, zlib

OUT, AEP, SIZES, VARIANTS = sys.argv[1], sys.argv[2], sys.argv[3].split(','), [v for v in sys.argv[4].split(',') if v]


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
    out = bytearray()
    prev = bytearray(stride)
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
        for x in range(0, stride, bpp):
            out += line[x:x + 3]
        prev = line
    return w, h, out


def stats(rgb):
    magenta = lit = orange = 0
    seen = set()
    for i in range(0, len(rgb), 3):
        r, g, b = rgb[i], rgb[i + 1], rgb[i + 2]
        if r > 200 and g < 60 and b > 200:
            magenta += 1
        if r > 150 and g < 130 and b < 90 and r - g > 50:
            orange += 1
        if r + g + b > 48:
            lit += 1
        seen.add((r >> 4, g >> 4, b >> 4))
    n = len(rgb) // 3
    return {'magenta': magenta, 'colours': len(seen), 'lit_pct': 100.0 * lit / n, 'orange_pct': 100.0 * orange / n}


results = {}
blob = open(AEP, 'rb').read() if os.path.exists(AEP) else b''
for raw in re.findall(rb'A3DSZ__[A-Za-z0-9_\-]+', blob):
    text = raw.decode().split('__end')[0]
    if text.endswith('LIST'):
        text = text[:-4]
    parts = text.split('__')
    if len(parts) < 2:
        continue
    kv = {}
    for part in parts[2:]:
        if '-' in part:
            k, v = part.split('-', 1)
            kv[k] = v
    results[parts[1]] = kv

problems = []
print('%-16s %-5s %-5s %-6s %-9s %-8s %-8s %s' % ('scene', 'built', 'rend', 'tries', 'ms', 'colours', 'lit %', 'verdict'))
for size in SIZES:
    w, h = [int(v) for v in size.split('x')]
    for var in VARIANTS:
        tag = '%dx%d_%s' % (w, h, var)
        r = results.get(tag)
        if r is None:
            problems.append('%s: no result (not reached: After Effects stopped or crashed before it)' % tag)
            print('%-16s no result' % tag)
            continue
        verdict, colours, lit = 'ok', '-', '-'
        if r.get('rend') != '1':
            verdict = 'render failed (%s)' % r.get('err', '?')
        else:
            try:
                pw, ph, rgb = read_png(os.path.join(OUT, tag + '.png'))
                if (pw, ph) != (w, h):
                    verdict = 'picture is %dx%d' % (pw, ph)
                else:
                    s = stats(rgb)
                    colours, lit = s['colours'], '%.1f' % s['lit_pct']
                    if s['magenta'] > w * h // 400:
                        verdict = 'magenta (failed Calder render)'
                    elif s['colours'] < 8 or s['lit_pct'] < 5.0:
                        verdict = 'blank picture'
                    elif s['orange_pct'] < 0.3:
                        verdict = 'the 3D text is not drawn (%.2f%% orange)' % s['orange_pct']
            except (OSError, ValueError, zlib.error, struct.error) as e:
                verdict = 'no picture (%s)' % e
        if verdict != 'ok':
            problems.append('%s: %s' % (tag, verdict))
        print('%-16s %-5s %-5s %-6s %-9s %-8s %-8s %s' % (tag, r.get('built', '?'), r.get('rend', '?'), r.get('try', '?'), r.get('ms', '?'), colours, lit, verdict))
if problems:
    print('SUMMARY FAIL: ' + '; '.join(problems))
    sys.exit(1)
print('SUMMARY PASS')
PY
RC=$?
echo "dialogs dismissed by the test:"
sort "$OUT/dialogs.log" 2> /dev/null | uniq -c | head -n 10
if [ "$RC" -eq 0 ]; then
    echo "PASS: every size renders a valid Advanced 3D picture (files in $OUT)"
else
    echo "FAIL: an Advanced 3D size failed (files in $OUT)"
fi
exit "$RC"
