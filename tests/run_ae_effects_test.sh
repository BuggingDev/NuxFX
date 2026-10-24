#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Effects coverage check, in CUDA mode and in software mode. Starts After Effects with a
# temporary startup script that applies about 40 common effects, by match name, each with one
# non-default parameter (the EFFECTS list of the startup script). Most effects go on an adjustment
# layer over a small test pattern (a gradient and two solids); the alpha-based ones (Drop Shadow,
# Stroke) go on the red box, because an adjustment layer has no alpha. Every effect has its own
# comp. Frame 0 of each comp is rendered with the project in the CUDA mode and again with
# GpuAccelType.SOFTWARE, and a base comp without effect is rendered in both modes as the reference.
# The PNGs are kept in AEGNUX_TEST_DIR/effects. The script reports the outcome in the names of the
# comps of a project it saves (scripts may not write files), in the form
# FX<nn>_<label>_app<0|1>_<parameter>_<mode>_<status>_<mode>_<status>. The shell then reads the frames.
# Per effect it reports: the change against the base comp ("vs base"), the difference between the
# CUDA and software frames, BLANK for a single-colour frame, NO VISIBLE CHANGE when the frame is
# within 0.5 of the base, and NOT FOUND when AE has no such match name. Match names given as
# AUTO:<display name> are looked up in app.effects at run time.
# Passes when After Effects stayed up to the end and every applied effect rendered a frame in both
# modes. Blank frames, unchanged frames, CUDA/software differences and missing match names are
# reported but do not fail the test.
#
# Env knobs: AEGNUX_TEST_WAIT (seconds, default 420), AEGNUX_TEST_DELAY (seconds before the script
# runs, default 30), AEGNUX_TEST_XVFB (1 = private display, default), AEGNUX_FX_LIMIT (test only the
# first N effects, default all), AEGNUX_TEST_DIR (frames and screenshots), AEGNUX_TEST_LOGDIR (keeps
# the Wine output). Same prerequisites and Xvfb handling as tests/run_ae_viewer_test.sh. The
# startup script is placed in "$AE_DIR/Scripts/Startup" and removed afterwards. Any running After
# Effects of this prefix is stopped.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S="$HERE/../scripts"
. "$S/common.sh"
WAIT="${AEGNUX_TEST_WAIT:-420}"
LIMIT="${AEGNUX_FX_LIMIT:-0}"
# The number of effects in the EFFECTS list of the startup script.
EXPECT=40
if [ "$LIMIT" -gt 0 ] && [ "$LIMIT" -lt "$EXPECT" ]; then EXPECT="$LIMIT"; fi

for t in xdotool xwininfo python3 gcc; do
    if ! command -v "$t" > /dev/null; then
        echo "FAIL: $t not installed ($(aegnux_pkg_hint xdotool x11-utils python3 gcc libx11-dev))"
        exit 1
    fi
done
if [ "${AEGNUX_DISABLE_CUDA:-0}" = 1 ]; then
    echo "note: AEGNUX_DISABLE_CUDA is 1, so both passes render in software and the comparison is void"
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
JSX="$USERDIR/aegnux_effects_test.jsx"
PROJECT="$USERDIR/aegnux_fx_result.aep"
PROJECT1="$USERDIR/aegnux_fx_pass1.aep"
FXDIR="$AEGNUX_TEST_DIR/effects"
STARTUP="$AE_DIR/Scripts/Startup/zz_aegnux_effects_test.jsx"
cleanup() {
    if [ -n "${AEGNUX_TEST_LOGDIR:-}" ]; then
        mkdir -p "$AEGNUX_TEST_LOGDIR"
        head -c 50000000 "$WORK/err.log" > "$AEGNUX_TEST_LOGDIR/effects_err.log" 2> /dev/null
        cp "$WORK/out.log" "$AEGNUX_TEST_LOGDIR/" 2> /dev/null
    fi
    rm -f "$STARTUP" "$JSX" "$PROJECT" "$PROJECT1" "$USERDIR"/aegnux_fx_*.png
    "$S/stop_ae.sh" > /dev/null 2>&1
    if [ -n "$XVFB_PID" ]; then kill "$XVFB_PID" 2> /dev/null; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
rm -f "$PROJECT" "$PROJECT1" "$USERDIR"/aegnux_fx_*.png
rm -rf "$FXDIR"

cat > "$JSX" << EOF
var U = "$U";
var LIMIT = $LIMIT;
EOF
cat >> "$JSX" << 'EOF'
var outDir = "C:/users/" + U + "/";
var project = new File(outDir + "aegnux_fx_result.aep");
var project1 = new File(outDir + "aegnux_fx_pass1.aep");
// [label, match names ("a|b"; AUTO:<display name> is looked up in app.effects), [[parameter regex, value], ...], layer]
// The parameter is the first property whose display name matches the regex. When none matches, the first
// slider gets 75 % (or 25 %) of its range. An empty list means the effect has no scripted parameter.
// The layer is "red" for the alpha-based effects, otherwise the adjustment layer.
var EFFECTS = [
    ["Gaussian Blur", "ADBE Gaussian Blur 2", [["^Blurriness$", 30]]],
    ["Fast Box Blur", "ADBE Fast Blur", [["^Blurriness$|^Blur Radius$", 20]]],
    ["Directional Blur", "ADBE Motion Blur|ADBE Directional Blur", [["^Blur Length$", 50]]],
    ["Radial Blur", "ADBE Radial Blur", [["^Amount$", 40]]],
    ["Compound Blur", "ADBE Compound Blur", [["^Maximum Blur$", 30]]],
    ["Channel Blur", "ADBE Channel Blur", [["^Red Blurriness$", 20]]],
    ["Glow", "ADBE Glo2", [["^Glow Radius$", 40]]],
    ["Drop Shadow", "ADBE Drop Shadow", [["^Distance$", 40]], "red"],
    ["Curves", "ADBE CurvesCustom|ADBE Curves", []],
    ["Levels", "ADBE Pro Levels2", [["^Input White$", 180]]],
    ["Hue/Saturation", "ADBE HUE SATURATION", [["^Master Hue$", 90], ["^Master Saturation$", 60]]],
    ["Brightness & Contrast", "ADBE Brightness & Contrast 2|ADBE Brightness & Contrast", [["^Brightness$", 40]]],
    ["Exposure", "ADBE Exposure2", [["^Exposure$", 1]]],
    ["Vibrance", "ADBE Vibrance", [["^Saturation$", 60], ["^Vibrance$", 60]]],
    ["Tint", "ADBE Tint", [["^Amount to Tint$", 100]]],
    ["Fill", "ADBE Fill", [["^Color$", [0, 0.4, 1]]]],
    ["Tritone", "ADBE Tritone", [["^Blend With Original$", 40]]],
    ["Invert", "ADBE Invert", [["^Blend With Original$", 25]]],
    ["Mosaic", "ADBE Mosaic", [["^Horizontal Blocks$", 20]]],
    ["Posterize", "ADBE Posterize", [["^Level$|^Levels$", 3]]],
    ["Threshold", "ADBE Threshold2|ADBE Threshold", [["^Level$|^Threshold$", 200]]],
    ["Noise", "ADBE Noise2", [["^Amount of Noise$", 40]]],
    ["Fractal Noise", "ADBE Fractal Noise", [["^Contrast$", 250]]],
    ["Turbulent Displace", "ADBE Turbulent Displace", [["^Amount$", 60]]],
    ["Displacement Map", "ADBE Displacement Map", [["^Max Horizontal Displacement$", 40]]],
    ["Bulge", "ADBE Bulge", [["^Bulge Height$", 50]]],
    ["Warp", "AUTO:Warp|ADBE Warp", [["^Bend$", 30]]],
    ["Spherize", "ADBE Spherize", [["^Radius$", 150]]],
    ["Polar Coordinates", "ADBE Polar Coordinates", [["^Interpolation$", 100], ["^Type of Conversion$", 2]]],
    ["Wave Warp", "ADBE Wave Warp", [["^Wave Height$", 60]]],
    ["Sharpen", "ADBE Sharpen", [["^Sharpen Amount$", 80]]],
    ["Unsharp Mask", "ADBE Unsharp Mask", [["^Amount$", 300]]],
    ["Find Edges", "ADBE Find Edges", [["^Blend With Original$", 50]]],
    ["Emboss", "ADBE Emboss", [["^Direction$", 90]]],
    ["Lens Flare", "ADBE Lens Flare", [["^Flare Brightness$", 150]]],
    ["Roughen Edges", "ADBE Roughen Edges", [["^Edge Roughness$|^Border$", 10]]],
    ["Stroke", "ADBE Stroke", [["^Brush Size$", 15]], "red"],
    ["Shift Channels", "ADBE Shift Channels", [["^Take Red From$", 3]]],
    ["Cartoon", "AUTO:Cartoon|ADBE Cartoon", [["^Line Thickness$|^Detail$", 8]]],
    ["Transform", "ADBE Geometry2", [["^Rotation$", 30]]]
];
function alnum(s) { return String(s).replace(/[^A-Za-z0-9]/g, "").substring(0, 40); }
function pad2(i) { return (i < 10 ? "0" : "") + i; }
function save(file) { try { app.project.save(file); } catch (e) { } }
function purge() { try { app.purge(PurgeTarget.ALL_CACHES); } catch (e) { } }
function hasGpu(key) { try { return typeof GpuAccelType[key] !== "undefined"; } catch (e) { return false; } }
// Switches the project's GPU acceleration; returns the key read back, or a failure word.
function setGpu(key) {
    if (!hasGpu(key)) { return "none"; }
    try {
        app.project.gpuAccelType = GpuAccelType[key];
        return app.project.gpuAccelType == GpuAccelType[key] ? key : "other";
    } catch (e) { return "noset"; }
}
// The match name of a display name, from app.effects (run time lookup); "" when AE does not list it.
function resolveAuto(disp) {
    try {
        for (var ei = 0; ei < app.effects.length; ei++) {
            if (String(app.effects[ei].displayName) === disp) { return String(app.effects[ei].matchName); }
        }
    } catch (e) { }
    return "";
}
// Applies the first match name AE accepts; returns {name, fx}, or null when none is accepted.
function addEffect(layer, names) {
    var parade = layer.property("ADBE Effect Parade");
    var list = names.split("|");
    for (var i = 0; i < list.length; i++) {
        var mn = list[i];
        if (mn.indexOf("AUTO:") === 0) { mn = resolveAuto(mn.substring(5)); }
        if (mn === "") { continue; }
        try {
            var fx = parade.addProperty(mn);
            if (fx !== null && fx !== undefined) { return { name: mn, fx: fx }; }
        } catch (e) { }
    }
    return null;
}
// Sets the first property whose display name matches rx to value; returns its name, or "".
function setParam(fx, rx, value) {
    var re = new RegExp(rx);
    for (var pi = 1; pi <= fx.numProperties; pi++) {
        var p = fx.property(pi);
        if (re.test(String(p.name))) {
            try { p.setValue(value); return String(p.name); } catch (e) { return ""; }
        }
    }
    return "";
}
// The fallback when no listed name matches: the first slider, set to 75 % (or 25 %) of its range.
function setFallback(fx) {
    for (var pi = 1; pi <= fx.numProperties; pi++) {
        var p = fx.property(pi);
        try {
            if (p.propertyValueType === PropertyValueType.OneD && p.maxValue > p.minValue) {
                var lo = p.minValue, hi = p.maxValue, v = p.value;
                p.setValue(v < (lo + hi) / 2 ? lo + 0.75 * (hi - lo) : lo + 0.25 * (hi - lo));
                return String(p.name);
            }
        } catch (e) { }
    }
    return "";
}
// Returns the token for the comp name: p1<name> (a listed parameter), pf<name> (the fallback slider),
// p0 (no parameter found) or pn (the effect has no scripted parameter).
function setParams(fx, list) {
    if (list.length === 0) { return "pn"; }
    var used = "";
    for (var j = 0; j < list.length; j++) {
        var nm = setParam(fx, list[j][0], list[j][1]);
        if (nm !== "" && used === "") { used = nm; }
    }
    if (used !== "") { return "p1" + alnum(used).substring(0, 20); }
    var fb = setFallback(fx);
    if (fb !== "") { return "pf" + alnum(fb).substring(0, 20); }
    return "p0";
}
// The test pattern: a gradient, a red and a blue solid, and an adjustment layer on top.
function buildPattern(comp) {
    var grad = comp.layers.addSolid([0.5, 0.5, 0.5], "pattern", 480, 270, 1.0);
    try { grad.property("ADBE Effect Parade").addProperty("ADBE Ramp"); } catch (e) { }
    var red = comp.layers.addSolid([1, 0, 0], "red box", 160, 90, 1.0);
    red.property("ADBE Transform Group").property("ADBE Position").setValue([150, 135]);
    var blue = comp.layers.addSolid([0, 0.4, 1], "blue box", 100, 100, 1.0);
    blue.property("ADBE Transform Group").property("ADBE Position").setValue([340, 150]);
    var adj = comp.layers.addSolid([0.5, 0.5, 0.5], "effect layer", 480, 270, 1.0);
    adj.adjustmentLayer = true;
    return { adj: adj, red: red };
}
// Renders frame 0 of a comp; the result is "ok", "nof" (no file) or "err<message>".
function renderTo(comp, fileName) {
    var f = new File(outDir + fileName);
    purge();
    try { comp.saveFrameToPng(0, f); } catch (e) { return "err" + alnum(e).substring(0, 30); }
    // The file can appear a moment after the call returns, so it is waited for (up to 10 s).
    for (var w = 0; w < 40 && !f.exists; w++) { $.sleep(250); }
    return f.exists ? "ok" : "nof";
}

// Lookup info: the GPU modes, and the display names that the AUTO entries are resolved from.
var knownKeys = ["CUDA", "SOFTWARE", "METAL", "OPENCL", "VULKAN", "NONE"];
var startKey = "unknown";
for (var k = 0; k < knownKeys.length; k++) {
    if (hasGpu(knownKeys[k]) && app.project.gpuAccelType == GpuAccelType[knownKeys[k]]) { startKey = knownKeys[k]; }
}
var enumKeys = [];
try { for (var ek in GpuAccelType) { enumKeys.push(alnum(ek)); } } catch (e) { enumKeys.push("noenum"); }
app.project.items.addComp("FXMODE_" + alnum(startKey) + "_" + enumKeys.join("_"), 480, 270, 1.0, 1, 30);
var findApi = "noapi";
try {
    findApi = "n" + app.effects.length;
    var found = 0;
    for (var ei = 0; ei < app.effects.length && found < 12; ei++) {
        var dn = String(app.effects[ei].displayName);
        if (/Warp|Cartoon|Motion Blur/i.test(dn)) {
            found++;
            var fmn = String(app.effects[ei].matchName).replace(/ /g, "_").replace(/[^A-Za-z0-9_]/g, "");
            app.project.items.addComp("FIND_" + dn.replace(/ /g, "_").replace(/[^A-Za-z0-9_]/g, "") + "_MN_" + fmn, 480, 270, 1.0, 1, 30);
        }
    }
} catch (e) { findApi = "err" + alnum(e); }
app.project.items.addComp("FINDAPI_" + findApi, 480, 270, 1.0, 1, 30);
var pass1Key = hasGpu("CUDA") ? "CUDA" : startKey;
var pass2Key = hasGpu("SOFTWARE") ? "SOFTWARE" : "none";

var n = (LIMIT > 0 && LIMIT < EFFECTS.length) ? LIMIT : EFFECTS.length;
var comps = [], matched = [], par = [], st1 = [], st2 = [];
// Comp names carry the result; the pending ones are replaced after pass 2.
function nameComp(i, g1, s1, g2, s2) {
    var nm = "FX" + pad2(i) + "_" + alnum(EFFECTS[i][0]) + "_" + (matched[i] === "" ? "app0" : "app1") + "_" + par[i] + "_" + g1 + "_" + s1 + "_" + g2 + "_" + s2;
    try {
        if (comps[i] === null) { comps[i] = app.project.items.addComp(nm, 480, 270, 1.0, 1, 30); }
        else { comps[i].name = nm; }
    } catch (e) { }
}

// Pass 1: CUDA (or the start mode when CUDA is not offered). The base comp has no effect and is
// the reference for "changed by the effect".
var g1 = setGpu(pass1Key);
var baseComp = app.project.items.addComp("fx base", 480, 270, 1.0, 1, 30);
buildPattern(baseComp);
var baseSt1 = renderTo(baseComp, "aegnux_fx_base_p1.png");
for (var i = 0; i < n; i++) {
    var comp = null;
    var mn = null;
    par[i] = "p0";
    try {
        comp = app.project.items.addComp("fx " + pad2(i), 480, 270, 1.0, 1, 30);
        var lay = buildPattern(comp);
        var target = (EFFECTS[i].length > 3 && EFFECTS[i][3] === "red") ? lay.red : lay.adj;
        mn = addEffect(target, EFFECTS[i][1]);
        if (mn !== null) { par[i] = setParams(mn.fx, EFFECTS[i][2]); }
    } catch (e) { mn = null; }
    comps[i] = comp;
    matched[i] = (mn === null) ? "" : mn.name;
    st1[i] = (mn === null || comp === null) ? "skip" : renderTo(comp, "aegnux_fx_" + pad2(i) + "_p1.png");
    if (comp !== null) { nameComp(i, g1, st1[i], "none", "pending"); }
}
save(project1);

// Pass 2: software mode, the same comps.
var g2 = setGpu(pass2Key);
var baseSt2 = renderTo(baseComp, "aegnux_fx_base_p2.png");
for (var i = 0; i < n; i++) {
    st2[i] = (matched[i] === "" || comps[i] === null) ? "skip" : renderTo(comps[i], "aegnux_fx_" + pad2(i) + "_p2.png");
}
setGpu(pass1Key);
for (var i = 0; i < n; i++) { nameComp(i, g1, st1[i], g2, st2[i]); }
try { baseComp.name = "FXBASE_" + g1 + "_" + baseSt1 + "_" + g2 + "_" + baseSt2; } catch (e) { }
save(project);
app.project.items.addComp("FXDONE", 480, 270, 1.0, 1, 30);
save(project);
EOF

printf 'app.scheduleTask("$.evalFile(new File(\x27C:/users/%s/aegnux_effects_test.jsx\x27))", %s, false);\n' "$U" "$(( ${AEGNUX_TEST_DELAY:-30} * 1000 ))" > "$STARTUP"

cat > "$WORK/ppm2png.py" << 'PY'
import struct, sys, zlib
data = open(sys.argv[1], 'rb').read()
fields, pos = [], 0
while len(fields) < 4:
    while data[pos:pos + 1].isspace():
        pos += 1
    start = pos
    while not data[pos:pos + 1].isspace():
        pos += 1
    fields.append(data[start:pos])
pos += 1
w, h = int(fields[1]), int(fields[2])
stride = w * 3
pix = data[pos:pos + stride * h]
raw = b''.join(b'\x00' + pix[y * stride:(y + 1) * stride] for y in range(h))
def chunk(kind, body):
    return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b'')
open(sys.argv[2], 'wb').write(png)
PY

shot() {
    local TARGET
    TARGET=$(xwininfo -root | awk '/Window id:/{print $4}')
    if [ -n "$TARGET" ] && "$WORK/xcap" "$TARGET" "$WORK/screen.ppm" > /dev/null 2>&1; then
        python3 -I "$WORK/ppm2png.py" "$WORK/screen.ppm" "$1" 2> /dev/null
    fi
}

mkdir -p "$AEGNUX_TEST_DIR"
"$S/stop_ae.sh" > /dev/null 2>&1
"$S/clear_crash_state.sh" > /dev/null
AEGNUX_COACHMARKS=0 "$S/ae_prefs.sh" > /dev/null
aegnux_env
cd "$AE_DIR" || exit 1
timeout $((WAIT + 30)) wine AfterFX.exe > "$WORK/out.log" 2> "$WORK/err.log" < /dev/null &
disown $!

# The loop ends when the final project has the FXDONE comp, or when After Effects exits.
T=0
CRASHED=0
DIALOGS=0
mkdir -p "$FXDIR"
: > "$AEGNUX_TEST_DIR/effects_windows.log"
while [ "$T" -lt "$WAIT" ]; do
    sleep 5
    T=$((T + 5))
    if [ -s "$PROJECT" ] && grep -aq 'FXDONE' "$PROJECT" 2> /dev/null; then break; fi
    if [ -z "$(aegnux_prefix_pids 'AfterFX.exe')" ]; then
        echo "After Effects is not running at ${T}s (crash or exit before the end)"
        CRASHED=1
        break
    fi
    for X in $(xdotool search --onlyvisible --class afterfx 2> /dev/null); do
        G=$(xwininfo -id "$X" 2> /dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')
        NM=$(xdotool getwindowname "$X" 2> /dev/null)
        if [ $((T % 30)) -eq 0 ]; then echo "t=${T}s: window $X $G [$NM]" >> "$AEGNUX_TEST_DIR/effects_windows.log"; fi
        case "$G" in
            # 430x211 and 494x200 are AE's own dialogs, 494x111 an error box, 494x141 a warning box
            # (as seen for the Cinema 4D renderer). Return is the default button of each.
            430x211|494x200|494x111|494x141)
                xdotool key --window "$X" Return 2> /dev/null
                DIALOGS=$((DIALOGS + 1))
                echo "t=${T}s: dismissed a $G dialog [$NM]" >> "$AEGNUX_TEST_DIR/effects_windows.log" ;;
        esac
    done
    # Adobe's System Compatibility Report waits for a click on "Continue with known issues".
    for X in $(xdotool search --onlyvisible --name "System Compatibility Report" 2> /dev/null); do
        xdotool mousemove --window "$X" 437 481 click 1 2> /dev/null
        DIALOGS=$((DIALOGS + 1))
        echo "t=${T}s: clicked Continue in the System Compatibility Report" >> "$AEGNUX_TEST_DIR/effects_windows.log"
    done
    if [ $((T % 60)) -eq 0 ]; then shot "$AEGNUX_TEST_DIR/effects_screen_t${T}.png"; fi
done
sleep 3
shot "$AEGNUX_TEST_DIR/effects_screen_final.png"

# The frames are copied before the cleanup removes them from the prefix.
cp "$USERDIR"/aegnux_fx_*.png "$FXDIR/" 2> /dev/null
SRC="$PROJECT"
DONE=0
if [ -s "$PROJECT" ] && grep -aq 'FXDONE' "$PROJECT" 2> /dev/null; then DONE=1; else SRC="$PROJECT1"; fi
if [ ! -s "$SRC" ]; then
    echo "FAIL: no effect results (After Effects did not save a project; screen: $AEGNUX_TEST_DIR/effects_screen_final.png)"
    exit 1
fi
[ "$DONE" -eq 1 ] || echo "note: the run did not finish; the results are from the pass-1 project"

python3 -I - "$SRC" "$FXDIR" "$EXPECT" "$DONE" "$CRASHED" << 'PY'
import collections, os, re, struct, sys, zlib

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

def flat_rgb(path):
    w, h, bpp, rows = read_png(path)
    buf = bytearray()
    for r in rows:
        if bpp == 3:
            buf += r
        else:
            for x in range(0, w * 4, 4):
                buf += r[x:x + 3]
    return w, h, bytes(buf)

def mean_abs_diff(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / float(len(a))

src, fxdir, expected, done, crashed = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == '1', sys.argv[5] == '1'
data = open(src, 'rb').read()
for m in sorted(set(re.findall(rb'FINDAPI_[A-Za-z0-9]{0,60}', data))):
    print('lookup: ' + m.decode())
for m in sorted(set(re.findall(rb'FIND_[A-Za-z0-9_]{0,120}', data))):
    print('lookup: ' + m.decode())
modes = re.findall(rb'FXMODE_([A-Za-z0-9_]*)', data)
if modes:
    print('GPU modes: start %s; enum: %s' % tuple(modes[0].decode().split('_', 1)))
# The status words are matched as whole words: the project stores the names without a terminator, so a
# greedy match would run into the binary bytes that follow (seen as "okLIST").
pat = rb'FX(\d\d)_([A-Za-z0-9]*)_(app[01])_(p[01fn][A-Za-z0-9]{0,30})_([A-Za-z]*)_(ok|nof|skip|pending|err[A-Za-z0-9]{0,40})_([A-Za-z]*)_(ok|nof|skip|pending|err[A-Za-z0-9]{0,40})'
rows = sorted(set(re.findall(pat, data)))
base1 = os.path.join(fxdir, 'aegnux_fx_base_p1.png')
base2 = os.path.join(fxdir, 'aegnux_fx_base_p2.png')
errors = 0
base_a = b''
if os.path.exists(base1) and os.path.exists(base2):
    base_a = flat_rgb(base1)[2]
else:
    print('no base frames: the change against the base cannot be measured')
    errors += 1
applied = blank = unchanged = identical = big = 0
maxdiff = 0.0
print('%-4s %-20s %-7s %-26s %-9s %-9s %-8s %-8s %s' % ('nn', 'effect', 'applied', 'parameter', 'CUDA', 'SOFTWARE', '|C-S|', 'vs base', 'result'))
for nn, label, app, par, m1, s1, m2, s2 in rows:
    nn, label, app, par, m1, s1, m2, s2 = [x.decode() for x in (nn, label, app, par, m1, s1, m2, s2)]
    if app != 'app1':
        print('%-4s %-20s %-7s %-26s %-9s %-9s %-8s %-8s %s' % (nn, label, 'no', '-', '-', '-', '-', '-', 'NOT FOUND'))
        continue
    applied += 1
    kind = par[:2]
    pname = par[2:]
    if kind == 'p1':
        ptxt = pname
    elif kind == 'pf':
        ptxt = 'fallback: ' + pname
    elif kind == 'pn':
        ptxt = '(none scripted)'
    else:
        ptxt = 'NONE FOUND'
    if s1 != 'ok' or s2 != 'ok':
        errors += 1
        print('%-4s %-20s %-7s %-26s %-9s %-9s %-8s %-8s %s' % (nn, label, 'yes', ptxt[:26], m1 + ' ' + s1, m2 + ' ' + s2, '-', '-', 'RENDER ERROR'))
        continue
    p1 = os.path.join(fxdir, 'aegnux_fx_%s_p1.png' % nn)
    p2 = os.path.join(fxdir, 'aegnux_fx_%s_p2.png' % nn)
    flags = []
    diff = changed = None
    try:
        w1, h1, a = flat_rgb(p1)
        w2, h2, b = flat_rgb(p2)
        diff = mean_abs_diff(a, b) if len(a) == len(b) else None
        if len(base_a) == len(a):
            changed = mean_abs_diff(a, base_a)
        for name, flat in (('CUDA', a), ('SOFTWARE', b)):
            counts = collections.Counter(flat[i:i + 3] for i in range(0, len(flat), 3))
            top, n = counts.most_common(1)[0]
            if n * 1000 >= (len(flat) // 3) * 999 or len(counts) < 2:
                flags.append('BLANK in %s' % name)
    except (OSError, ValueError, zlib.error) as e:
        errors += 1
        flags.append('unreadable PNG (%s)' % e)
    if any(f.startswith('BLANK') for f in flags):
        blank += 1
    if changed is not None and changed < 0.5:
        unchanged += 1
        flags.append('NO VISIBLE CHANGE')
    if diff is not None:
        maxdiff = max(maxdiff, diff)
        if diff == 0:
            identical += 1
        if diff > 2.0:
            big += 1
            flags.append('CUDA-SW > 2.0')
    verdict = 'OK' if not flags else '; '.join(flags)
    print('%-4s %-20s %-7s %-26s %-9s %-9s %-8s %-8s %s' % (
        nn, label, 'yes', ptxt[:26], m1 + ' ok', m2 + ' ok',
        '-' if diff is None else '%.2f' % diff,
        '-' if changed is None else '%.2f' % changed, verdict))
listed = len(rows)
print('summary: %d of %d effects reported, %d applied, %d render errors, %d blank frames, %d with no visible change (vs base < 0.5), %d identical CUDA/software, %d with CUDA/software difference above 2.0 (max %.2f)' % (
    listed, expected, applied, errors, blank, unchanged, identical, big, maxdiff))
ok = done and not crashed and listed >= expected and errors == 0 and applied >= 1
sys.exit(0 if ok else 1)
PY
RC=$?
echo "dialogs dismissed: $DIALOGS (see $AEGNUX_TEST_DIR/effects_windows.log)"
if [ "$CRASHED" -eq 1 ]; then echo "After Effects exited before the end of the run"; fi
if [ "$RC" -eq 0 ]; then
    echo "PASS: After Effects stayed up to the end and every applied effect rendered a frame in CUDA and in software mode"
elif [ "$CRASHED" -eq 1 ] || [ "$DONE" -eq 0 ]; then
    echo "FAIL: the run did not finish (After Effects exited or timed out; partial results in $FXDIR)"
else
    echo "FAIL: some applied effects did not render a frame in both modes (see the table; frames in $FXDIR)"
fi
exit "$RC"
