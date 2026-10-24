#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Scene coverage of the Advanced 3D renderer (ADBE Calder). tests/run_ae_advanced3d_test.sh renders
# one tilted solid. This test starts After Effects once, builds small comps (480x270, renderer
# ADBE Calder, project GPU type CUDA) for six scenes, renders frame 0 of each to a PNG and checks
# the pictures in Python:
#   cam     a camera moved by 200 px in z changes the picture
#   light   a point light changes the picture, and the lit side is brighter than with the light off
#   shadow  an Environment light with Casts Shadows on puts a darker region on a wall, and the text
#           that casts it is drawn
#   text    3D text with Extrusion Depth > 0 (Advanced 3D) differs from Classic 3D (ADBE Advanced 3d)
#   env     an Environment light (LightType.ENVIRONMENT) lights a 3D text layer
#   stress  30 small 3D solids at random z positions under 2 point lights
# Every picture must be valid: no magenta (the colour of a failed Calder render) and not a single
# colour. A feature that ExtendScript does not expose is reported as "not scriptable" and does not
# fail the test. Passes if every selected scene is built, rendered and passes its check.
#
# The results come back in the NAMES of the comps of a project that the script saves (scripts may
# not write files). Knobs (all optional):
#   AEGNUX_A3D_SCENES     comma-separated subset of cam,light,shadow,text,env,stress (default all)
#   AEGNUX_A3D_WINEDEBUG  WINEDEBUG for this run (default err+all,warn+vulkan)
#   AEGNUX_TEST_DELAY     seconds after the start before the scenes are built (default 30)
#   AEGNUX_TEST_WAIT      seconds to wait for the results (default 240)
#   AEGNUX_TEST_LOGDIR    keep the Wine stdout/stderr and the dialog log there
# The pictures, the project, the dialog log and the Wine lines about Calder, DXVK, vkd3d or a lost
# device go to $AEGNUX_TEST_DIR/advanced3d_scene. Needs the CUDA bridge (AEGNUX_DISABLE_CUDA=0) and
# the prerequisites of tests/run_ae_advanced3d_test.sh. Only a private Xvfb is used
# (AEGNUX_TEST_XVFB must stay 1). Any running After Effects of this prefix is stopped.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S="$HERE/../scripts"
. "$S/common.sh"
WAIT="${AEGNUX_TEST_WAIT:-240}"
DELAY="${AEGNUX_TEST_DELAY:-30}"
SCENES=$(printf '%s' "${AEGNUX_A3D_SCENES:-cam,light,shadow,text,env,stress}" | tr -cd 'a-z,')
OUT="$AEGNUX_TEST_DIR/advanced3d_scene"

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

# A private display: the numbers of other distributions' servers are taken too (see
# tests/run_ae_advanced3d_test.sh). The inherited DISPLAY is never used.
N=99
while [ -e "/tmp/.X$N-lock" ] || grep -q "@/tmp/.X11-unix/X$N\$" /proc/net/unix 2> /dev/null; do N=$((N - 1)); done
Xvfb ":$N" -screen 0 1920x1080x24 -nolisten tcp > /dev/null 2>&1 &
XVFB_PID=$!
export DISPLAY=":$N"
for _ in $(seq 1 50); do xwininfo -root > /dev/null 2>&1 && break; sleep 0.2; done
xwininfo -root > /dev/null 2>&1 || { echo "FAIL: Xvfb did not start on $DISPLAY"; kill "$XVFB_PID" 2> /dev/null; exit 1; }
# Wine uses its Wayland driver when WAYLAND_DISPLAY is set, and the windows would not appear
# on the private X display.
unset WAYLAND_DISPLAY

U=$(aegnux_win_user)
USERDIR="$WINEPREFIX/drive_c/users/$U"
JSX="$USERDIR/aegnux_a3d_scene_test.jsx"
PROJECT="$USERDIR/aegnux_a3d_scene_result.aep"
SHOT="$USERDIR/aegnux_a3d_scene_"
STARTUP="$AE_DIR/Scripts/Startup/zz_aegnux_a3d_scene_test.jsx"
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

# The paths and the scene list come first (shell values), then the ExtendScript body.
cat > "$JSX" << EOF
var SHOT = "C:/users/$U/aegnux_a3d_scene_";
var PROJECT_PATH = "C:/users/$U/aegnux_a3d_scene_result.aep";
var SCENES = ",$SCENES,";
EOF
cat >> "$JSX" << 'EOF'
// ExtendScript is ECMAScript 3: var only, no arrow functions, no ES5 array methods, no trailing commas.
var W = 480;
var H = 270;
var GPU_NAMES = ["CUDA", "METAL", "OPENCL", "SOFTWARE", "VULKAN"];
var PALETTE = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0], [0, 1, 1], [1, 0.5, 0], [1, 1, 1], [0.5, 0.5, 0.5]];
var RND_SEED = 12345;
var NOTE = "";
var GPU = "unknown";
var JOBS = [];

// A name part: letters, digits and "_" only ("-" and "__" separate the fields of a result name).
function safeN(s, n) {
    var t = String(s).replace(/[^A-Za-z0-9]/g, "_");
    while (t.indexOf("__") >= 0) { t = t.replace(/__/g, "_"); }
    return t.substring(0, n);
}
function safe(s) { return safeN(s, 80); }

// Diagnostics (refusals, property details) go to comps of their own, A3DDIAG__, because a comp
// name holds about 250 characters.
var DIAG = [];
function pushDiag(label, text) {
    var s = String(text);
    for (var k = 0; k * 170 < s.length || k === 0; k++) {
        DIAG.push(label + " " + (k + 1) + ": " + s.substring(k * 170, (k + 1) * 170));
    }
}
function describe(p) {
    var s = "";
    try { s += " mn=" + p.matchName; } catch (e1) { }
    try { s += " pt=" + p.propertyType; } catch (e2) { }
    try { s += " vt=" + p.propertyValueType; } catch (e3) { }
    try { s += " min=" + p.minValue + " max=" + p.maxValue; } catch (e4) { }
    try { s += " v=" + p.value; } catch (e5) { }
    return s;
}
// Tries the candidate values in turn and returns the first one that is accepted, or null. The
// refusals are kept in the diagnostics. It never throws.
function setTry(p, candidates, label) {
    if (!p) { pushDiag(label, "property not found"); return null; }
    var errs = "";
    for (var i = 0; i < candidates.length; i++) {
        try {
            p.setValue(candidates[i]);
            pushDiag(label, "set " + String(candidates[i]) + " ok" + describe(p));
            return candidates[i];
        } catch (e) {
            errs += " [" + String(candidates[i]) + "] " + String(e);
        }
    }
    pushDiag(label, "refused" + describe(p) + errs);
    return null;
}
function collectLeaves(group, n, out, d) {
    if (d > 6) { return; }
    for (var i = 1; i <= group.numProperties; i++) {
        var p = group.property(i);
        if (p.propertyType == PropertyType.PROPERTY) {
            if (String(p.matchName).toLowerCase().indexOf(n) >= 0 || String(p.name).toLowerCase().indexOf(n) >= 0) { out.push(String(p.matchName)); }
        } else {
            collectLeaves(p, n, out, d + 1);
        }
    }
}
function listProps(group, needle, label) {
    var out = [];
    collectLeaves(group, needle.toLowerCase(), out, 0);
    pushDiag(label + " props", out.join(" ") + " (" + out.length + ")");
}

// The project GPU type (app.project.gpuAccelType) as a name.
function gpuName() {
    var name = "unknown";
    try {
        for (var i = 0; i < GPU_NAMES.length; i++) {
            if (typeof GpuAccelType[GPU_NAMES[i]] !== "undefined" && app.project.gpuAccelType == GpuAccelType[GPU_NAMES[i]]) {
                name = GPU_NAMES[i];
            }
        }
    } catch (e) { name = "err"; }
    return name;
}

// First leaf property below group whose matchName or name contains needle (case-insensitive).
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

function newComp(name, renderer) {
    var c = app.project.items.addComp(name, W, H, 1.0, 5, 30);
    c.renderer = renderer;
    return c;
}

function solid3d(comp, name, rgb, w, h, pos, ori) {
    var s = comp.layers.addSolid(rgb, name, w, h, 1.0);
    s.threeDLayer = true;
    s.property("ADBE Transform Group").property("ADBE Position").setValue(pos);
    s.property("ADBE Transform Group").property("ADBE Orientation").setValue(ori);
    return s;
}

function addPointLight(comp, name, pos, intensity) {
    var lt = comp.layers.addLight(name, [pos[0], pos[1]]);
    lt.lightType = LightType.POINT;
    lt.property("ADBE Transform Group").property("ADBE Position").setValue(pos);
    findProp(lt, "Light Intensity").setValue(intensity);
    return lt;
}

// Advanced 3D shadows and image-based lighting use a Light layer of type Environment
// (AE 24.3+). The old Layer > Environment Layer switch is for the Cinema 4D renderer only.
function addEnvLight(comp, name) {
    var lt = comp.layers.addLight(name, [W / 2, H / 2]);
    try {
        lt.lightType = LightType.ENVIRONMENT;
        pushDiag("envlight", "lightType=" + lt.lightType);
    } catch (e) {
        pushDiag("envlight", "lightType refused: " + String(e));
        NOTE += " envlight_notset";
    }
    var ip = findProp(lt, "Light Intensity");
    if (ip) { setTry(ip, [100], "env intensity"); }
    return lt;
}

// Casts Shadows is a checkbox on a light (0/1 or true/false) and a menu on a layer. On the menu
// 2 is "Only": the layer is not drawn and only its shadow is. 1 draws the layer and casts the
// shadow, so the caster is set to 1 (an earlier version of this test used 2, and the text in the
// shadow pictures was never drawn).
function setCastsShadows(layer, on, isLight) {
    var p = findProp(layer, "Casts Shadows");
    var tag = (isLight ? "lightshadow_" : "layershadow_") + (on ? "on" : "off");
    if (!p) { NOTE += " " + tag + "_notfound"; return; }
    var got = isLight ? setTry(p, [on ? 1 : 0, on], tag) : setTry(p, [1], tag);
    if (got === null) { NOTE += " " + tag + "_notset"; }
    else { NOTE += " " + tag + "_" + p.value; }
}

// A two-node camera has a Point of Interest; a one-node camera does not. addCamera makes a
// two-node camera, so the note tells which kind the test used.
function addCamera(comp, z) {
    var cam = comp.layers.addCamera("cam", [W / 2, H / 2]);
    cam.property("ADBE Transform Group").property("ADBE Position").setValue([W / 2, H / 2, z]);
    NOTE += (findProp(cam, "Point of Interest") ? " cam_twonode" : " cam_onenode");
    return cam;
}

function buildCam(z) {
    var comp = newComp("a3d cam " + z, "ADBE Calder");
    solid3d(comp, "tilted", [1, 0, 0], 220, 160, [W / 2, H / 2, 0], [25, 35, 0]);
    addCamera(comp, z);
    return comp;
}

function buildLight(on) {
    var comp = newComp("a3d light " + (on ? "on" : "off"), "ADBE Calder");
    solid3d(comp, "lit box", [0.9, 0.5, 0.1], 260, 180, [W / 2, H / 2, 0], [20, 35, 0]);
    var lt = addPointLight(comp, "point light", [60, 40, -400], 100);
    lt.enabled = on;
    return comp;
}

function buildShadow(on) {
    var comp = newComp("a3d shadow " + (on ? "on" : "off"), "ADBE Calder");
    // A wall behind the text receives the shadow; the text is the extruded caster.
    var wall = solid3d(comp, "wall", [0.85, 0.85, 0.85], 1200, 1200, [W / 2, H / 2, 300], [0, 0, 0]);
    findProp(wall, "Accepts Shadows").setValue(1);
    var tl = comp.layers.addText("SHADOW");
    tl.threeDLayer = true;
    var doc = tl.property("ADBE Text Properties").property("ADBE Text Document");
    var td = doc.value;
    td.fontSize = 90;
    td.fillColor = [0.9, 0.2, 0.2];
    doc.setValue(td);
    tl.property("ADBE Transform Group").property("ADBE Position").setValue([W / 2 - 50, H / 2 - 30, 0]);
    var ext = findProp(tl, "Extrsn Depth");
    if (ext) { setTry(ext, [80], "shadow extrusion"); }
    findProp(tl, "Accepts Shadows").setValue(1);
    setCastsShadows(tl, true, false);
    addCamera(comp, -700);
    var lt = addEnvLight(comp, "environment light");
    listProps(lt, "hadow", "light " + (on ? "on" : "off"));
    setCastsShadows(lt, on, true);
    return comp;
}

function buildText(renderer) {
    var comp = newComp("a3d text " + renderer, renderer);
    var tl = comp.layers.addText("3D TEXT");
    tl.threeDLayer = true;
    var doc = tl.property("ADBE Text Properties").property("ADBE Text Document");
    var td = doc.value;
    td.fontSize = 60;
    td.fillColor = [1, 0.3, 0];
    doc.setValue(td);
    tl.property("ADBE Transform Group").property("ADBE Position").setValue([W / 2, H / 2, 0]);
    tl.property("ADBE Transform Group").property("ADBE Orientation").setValue([15, -25, 0]);
    var ext = findProp(tl, "Extrsn Depth");
    listProps(tl, "xtr", "text " + renderer);
    if (!ext) { NOTE += " extr_notfound"; }
    else {
        // Classic 3D has no extrusion, so a refusal there is the expected result.
        NOTE += (setTry(ext, [40], "extrusion " + renderer) === null) ? " extr_notset" : " extr_ok";
        NOTE += " extr_" + safe(ext.matchName);
    }
    return comp;
}

function buildEnv(on) {
    var comp = newComp("a3d env " + (on ? "on" : "off"), "ADBE Calder");
    // A diffuse wall and extruded text are lit by the default environment map.
    solid3d(comp, "wall", [0.55, 0.55, 0.6], 1200, 1200, [W / 2, H / 2, 300], [0, 0, 0]);
    var tl = comp.layers.addText("IBL");
    tl.threeDLayer = true;
    var doc = tl.property("ADBE Text Properties").property("ADBE Text Document");
    var td = doc.value;
    td.fontSize = 100;
    td.fillColor = [0.85, 0.85, 0.85];
    doc.setValue(td);
    tl.property("ADBE Transform Group").property("ADBE Position").setValue([W / 2, H / 2, 0]);
    var ext = findProp(tl, "Extrsn Depth");
    if (ext) { setTry(ext, [60], "env extrusion"); }
    addCamera(comp, -600);
    // A dim fill light keeps the control picture visible; the Environment light is the variable.
    addPointLight(comp, "fill light", [W / 2, H / 2, -500], 40);
    var lt = addEnvLight(comp, "environment light");
    var ip = findProp(lt, "Light Intensity");
    if (ip) { setTry(ip, [on ? 300 : 0], "env level"); }
    listProps(lt, "ntensity", "env light");
    return comp;
}

// Park-Miller generator: the same positions in every run.
function rnd() {
    RND_SEED = (RND_SEED * 16807) % 2147483647;
    return RND_SEED / 2147483647;
}

function buildStress() {
    var comp = newComp("a3d stress", "ADBE Calder");
    for (var i = 0; i < 30; i++) {
        var c = PALETTE[Math.floor(rnd() * PALETTE.length)];
        var size = 24 + Math.floor(rnd() * 36);
        var pos = [Math.floor(rnd() * W), Math.floor(rnd() * H), Math.round(rnd() * 800 - 400)];
        var ori = [Math.floor(rnd() * 90), Math.floor(rnd() * 90), 0];
        solid3d(comp, "solid " + i, c, size, size, pos, ori);
    }
    addPointLight(comp, "light a", [100, 40, -500], 80);
    addPointLight(comp, "light b", [380, 230, -500], 80);
    return comp;
}

function addJob(scene, tag, renderer, fn) {
    JOBS.push({scene: scene, tag: tag, renderer: renderer, fn: fn});
}
addJob("cam", "cam_a", "ADBE Calder", function () { return buildCam(-1000); });
addJob("cam", "cam_b", "ADBE Calder", function () { return buildCam(-800); });
addJob("light", "light_on", "ADBE Calder", function () { return buildLight(true); });
addJob("light", "light_off", "ADBE Calder", function () { return buildLight(false); });
addJob("shadow", "shadow_on", "ADBE Calder", function () { return buildShadow(true); });
addJob("shadow", "shadow_off", "ADBE Calder", function () { return buildShadow(false); });
addJob("text", "text_calder", "ADBE Calder", function () { return buildText("ADBE Calder"); });
addJob("text", "text_classic", "ADBE Advanced 3d", function () { return buildText("ADBE Advanced 3d"); });
addJob("env", "env_on", "ADBE Calder", function () { return buildEnv(true); });
addJob("env", "env_off", "ADBE Calder", function () { return buildEnv(false); });
addJob("stress", "stress", "ADBE Calder", function () { return buildStress(); });

// Renders frame 0 to a PNG. A first Calder render can fail while shaders are compiled, so it is
// tried again a few times.
function renderPng(comp, tag) {
    var file = new File(SHOT + tag + ".png");
    var res = {ok: false, tries: 0, err: ""};
    for (var a = 0; a < 6 && !res.ok; a++) {
        res.tries++;
        try {
            comp.saveFrameToPng(0, file);
            res.ok = file.exists;
        } catch (e) { res.err = String(e); pushDiag("render " + tag, res.err); }
        if (!res.ok) { $.sleep(2000); }
    }
    return res;
}

// The result of one scene goes into the name of its comp, and the project is saved, so the
// shell sees every finished scene even if After Effects stops later.
function record(comp, tag, built, rend, rendererGot) {
    var name = "A3DRES__" + tag + "__built-" + built + "__rend-" + (rend.ok ? 1 : 0) + "__try-" + rend.tries +
        "__renderer-" + safe(rendererGot) + "__gpu-" + GPU + "__err-" + (rend.err ? safe(rend.err) : "none") +
        "__note-" + safe(NOTE) + "__end";
    comp.name = name.substring(0, 250);
    app.project.save(new File(PROJECT_PATH));
}

try {
    GPU = gpuName();
    for (var j = 0; j < JOBS.length; j++) {
        var jb = JOBS[j];
        if (SCENES.indexOf("," + jb.scene + ",") < 0) { continue; }
        NOTE = "";
        var comp = null;
        var built = 0;
        try { comp = jb.fn(); built = 1; } catch (e) { NOTE += " build_" + safeN(e, 40); pushDiag("build " + jb.tag, String(e)); }
        if (!comp) {
            try { comp = newComp("a3d placeholder " + jb.tag, jb.renderer); }
            catch (e2) { comp = app.project.items.addComp("a3d placeholder", W, H, 1.0, 5, 30); }
        }
        var rendererGot = "none";
        try { rendererGot = comp.renderer; } catch (e3) { rendererGot = "err"; }
        var rend = {ok: false, tries: 0, err: "not rendered"};
        if (built) { rend = renderPng(comp, jb.tag); }
        record(comp, jb.tag, built, rend, rendererGot);
    }
    for (var k = 0; k < DIAG.length; k++) {
        app.project.items.addComp("A3DDIAG__" + (k < 10 ? "0" : "") + k + "__" + safeN(DIAG[k], 180) + "__end", 16, 16, 1.0, 1, 30);
    }
    app.project.save(new File(PROJECT_PATH));
    app.project.items.addComp("A3DRES__done__gpu-" + GPU, 16, 16, 1.0, 1, 30);
    app.project.save(new File(PROJECT_PATH));
} catch (e4) {
    app.project.items.addComp("A3DRES__fatal__err-" + safe(e4), 16, 16, 1.0, 1, 30);
    app.project.save(new File(PROJECT_PATH));
}
EOF
printf 'app.scheduleTask("$.evalFile(new File(\x27C:/users/%s/aegnux_a3d_scene_test.jsx\x27))", %s, false);\n' "$U" "$((DELAY * 1000))" > "$STARTUP"

"$S/stop_ae.sh" > /dev/null 2>&1
"$S/clear_crash_state.sh" > /dev/null
AEGNUX_COACHMARKS=0 "$S/ae_prefs.sh" > /dev/null
export WINEDEBUG="${AEGNUX_A3D_WINEDEBUG:-err+all,warn+vulkan}"
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
        # Adobe's System Compatibility Report waits for a click on "Continue with known issues".
        for X in $(xdotool search --onlyvisible --name "System Compatibility Report" 2> /dev/null); do
            echo "$(date +%T) clicked the System Compatibility Report" >> "$WORK/dialogs.log"
            xdotool mousemove --window "$X" 437 481 click 1 2> /dev/null
        done
    done
) &
DISMISS_PID=$!

T=0
while [ "$T" -lt "$WAIT" ]; do
    sleep 3
    T=$((T + 3))
    grep -q -a -E 'A3DRES__(done|fatal)' "$PROJECT" 2> /dev/null && break
    if [ "$T" -ge 30 ] && [ -z "$(aegnux_prefix_pids 'AfterFX[.]exe')" ]; then
        echo "note: After Effects exited before the scenes were done"
        break
    fi
done
sleep 2

TARGET=$(xwininfo -root | awk '/Window id:/{print $4}')
"$WORK/xcap" "$TARGET" "$OUT/screen.ppm" > /dev/null 2>&1
for f in "$SHOT"*.png; do
    [ -f "$f" ] && cp "$f" "$OUT/$(basename "$f" | sed 's/^aegnux_a3d_scene_//')"
done
kill "$DISMISS_PID" 2> /dev/null
DISMISS_PID=""
"$S/stop_ae.sh" > /dev/null 2>&1
[ -f "$PROJECT" ] && cp "$PROJECT" "$OUT/result.aep"
cp "$WORK/dialogs.log" "$WORK/windows.log" "$OUT/" 2> /dev/null
cp "$WORK/out.log" "$OUT/wine_stdout.log" 2> /dev/null
grep -a -i -E 'calder|dxvk|vkd3d|device lost|device_lost|vk_error|dzn|unhandled exception|page fault|c0000005' "$WORK/err.log" > "$OUT/wine_lines.txt" 2> /dev/null
# The Calder console (renderWarn, AgRender...) goes to stdout.
grep -a -i -E 'renderwarn|rendererror|calder|agrender|desynchron' "$WORK/out.log" >> "$OUT/wine_lines.txt" 2> /dev/null
echo "wine err lines: $(grep -a -c '^err:' "$WORK/err.log" 2> /dev/null), lines about Calder/DXVK/vkd3d/lost device: $(wc -l < "$OUT/wine_lines.txt")"

python3 -I - "$OUT" "$PROJECT" "$SCENES" << 'PY'
import os, re, struct, sys, zlib

OUT, AEP, WANT = sys.argv[1], sys.argv[2], sys.argv[3]
W, H = 480, 270
SCENE_TAGS = [
    ('cam', ['cam_a', 'cam_b']),
    ('light', ['light_on', 'light_off']),
    ('shadow', ['shadow_on', 'shadow_off']),
    ('text', ['text_calder', 'text_classic']),
    ('env', ['env_on', 'env_off']),
    ('stress', ['stress']),
]
WANTED = [s for s in WANT.split(',') if s]
EXPECT = {'text_classic': 'ADBE_Advanced_3d'}


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
    if ihdr is None:
        raise ValueError('no IHDR')
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
    magenta = lit = lum = red = 0
    seen = set()
    n = len(rgb) // 3
    for i in range(0, len(rgb), 3):
        r, g, b = rgb[i], rgb[i + 1], rgb[i + 2]
        if r > 200 and g < 60 and b > 200:
            magenta += 1
        if r - max(g, b) > 25:
            red += 1
        if r + g + b > 48:
            lit += 1
        seen.add((r >> 4, g >> 4, b >> 4))
        lum += 299 * r + 587 * g + 114 * b
    return {'magenta': magenta, 'colours': len(seen), 'lit': lit, 'red': red, 'mean_lum': lum / (1000.0 * n)}


def compare(a, b):
    # "a" is the picture with the feature on, "b" the one without: brighter counts the pixels
    # where a is more than 20 levels brighter, darker the pixels where a is more than 25 levels
    # darker (and bbox encloses them).
    n = len(a) // 3
    total = big = brighter = darker = 0
    x0, y0, x1, y1 = W, H, -1, -1
    for p in range(n):
        i = p * 3
        dr, dg, db = abs(a[i] - b[i]), abs(a[i + 1] - b[i + 1]), abs(a[i + 2] - b[i + 2])
        total += dr + dg + db
        if max(dr, dg, db) > 32:
            big += 1
        la = 299 * a[i] + 587 * a[i + 1] + 114 * a[i + 2]
        lb = 299 * b[i] + 587 * b[i + 1] + 114 * b[i + 2]
        if la - lb > 20000:
            brighter += 1
        if lb - la > 25000:
            darker += 1
            x, y = p % W, p // W
            x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
    return {'mean': total / (3.0 * n), 'big': big, 'brighter': brighter, 'darker': darker,
            'bbox': (x0, y0, x1, y1)}


results = {}
diags = []
seen = set()
blob = open(AEP, 'rb').read() if os.path.exists(AEP) else b''
for raw in re.findall(rb'A3D(?:RES|DIAG)__[A-Za-z0-9_\-]+', blob):
    # The names are followed by the next chunk tag of the project file (LIST), and "__end" ends them.
    text = raw.decode().split('__end')[0]
    if text.endswith('LIST'):
        text = text[:-4]
    if text.startswith('A3DDIAG__'):
        if text not in seen:
            seen.add(text)
            diags.append(text[len('A3DDIAG__'):])
        continue
    parts = text.split('__')
    if len(parts) < 2:
        continue
    kv = {}
    for part in parts[2:]:
        if '-' in part:
            k, v = part.split('-', 1)
            kv[k] = v
    results[parts[1]] = kv

pics, perr = {}, {}
for scene, tags in SCENE_TAGS:
    for tag in tags:
        try:
            w, h, rgb = read_png(os.path.join(OUT, tag + '.png'))
            if (w, h) != (W, H):
                raise ValueError('size %dx%d' % (w, h))
            pics[tag] = rgb
        except (OSError, ValueError, zlib.error, struct.error) as e:
            perr[tag] = str(e)

problems = []
feature = {}
print('%-8s %-13s %-5s %-5s %-14s %-6s %-8s %-8s %s' % ('scene', 'tag', 'built', 'rend', 'renderer', 'gpu', 'magenta', 'colours', 'notes'))
for scene, tags in SCENE_TAGS:
    if scene not in WANTED:
        continue
    for tag in tags:
        r = results.get(tag)
        if r is None:
            problems.append('%s: no result (not built, or After Effects stopped first)' % tag)
            print('%-8s %-13s no result' % (scene, tag))
            continue
        want = EXPECT.get(tag, 'ADBE_Calder')
        if r.get('built') != '1':
            problems.append('%s: scene not built' % tag)
        if r.get('rend') != '1':
            problems.append('%s: render failed (%s)' % (tag, r.get('err', '?')))
        if r.get('gpu') != 'CUDA':
            problems.append('%s: project GPU type is %s, expected CUDA' % (tag, r.get('gpu', '?')))
        if r.get('renderer') != want:
            problems.append('%s: renderer %s, expected %s' % (tag, r.get('renderer', '?'), want))
        magenta, colours = '-', '-'
        if tag in pics:
            s = stats(pics[tag])
            magenta, colours = s['magenta'], s['colours']
            if magenta > 260:
                problems.append('%s: %d magenta pixels (failed Calder render?)' % (tag, magenta))
            if colours < 2:
                problems.append('%s: picture is a single colour' % tag)
        else:
            problems.append('%s: no picture (%s)' % (tag, perr.get(tag, 'missing')))
        print('%-8s %-13s %-5s %-5s %-14s %-6s %-8s %-8s %s' % (scene, tag, r.get('built', '?'), r.get('rend', '?'),
              r.get('renderer', '?'), r.get('gpu', '?'), magenta, colours, r.get('note', '')))


def pic(tag):
    return pics.get(tag)


if 'cam' in WANTED and pic('cam_a') and pic('cam_b'):
    c = compare(pic('cam_a'), pic('cam_b'))
    ok = c['mean'] >= 1.0 and c['big'] >= 500
    feature['cam'] = ('OK' if ok else 'FAIL', 'mean diff %.2f, px diff %d' % (c['mean'], c['big']))
if 'light' in WANTED and pic('light_on') and pic('light_off'):
    c = compare(pic('light_on'), pic('light_off'))
    lo, lf = stats(pic('light_on'))['mean_lum'], stats(pic('light_off'))['mean_lum']
    ok = c['mean'] >= 1.0 and c['big'] >= 300 and c['brighter'] >= 100 and lo > lf
    feature['light'] = ('OK' if ok else 'FAIL', 'mean diff %.2f, px diff %d, lit-side px %d, mean lum on %.1f off %.1f'
                        % (c['mean'], c['big'], c['brighter'], lo, lf))
if 'shadow' in WANTED and pic('shadow_on') and pic('shadow_off') and 'lightshadow_on_notset' in results.get('shadow_on', {}).get('note', ''):
    feature['shadow'] = ('NOT SCRIPTABLE', 'the Environment light Casts Shadows property refuses the script values (see the diagnostics)')
elif 'shadow' in WANTED and pic('shadow_on') and pic('shadow_off'):
    c = compare(pic('shadow_on'), pic('shadow_off'))
    so, sf = stats(pic('shadow_on')), stats(pic('shadow_off'))
    lo, lf = so['mean_lum'], sf['mean_lum']
    # The caster has to be drawn as well as its shadow (Casts Shadows "Only" hides the layer). The
    # wall is grey, so the reddish pixels are the text (about 10000 in both pictures).
    ok = c['darker'] >= 150 and lo < lf and min(so['red'], sf['red']) >= 2000
    feature['shadow'] = ('OK' if ok else 'FAIL', 'darker px %d bbox %s, mean lum on %.1f off %.1f, text px on %d off %d'
                         % (c['darker'], c['bbox'], lo, lf, so['red'], sf['red']))
if 'text' in WANTED and pic('text_calder') and pic('text_classic'):
    c = compare(pic('text_calder'), pic('text_classic'))
    ok = c['mean'] >= 1.0 and c['big'] >= 300
    feature['text'] = ('OK' if ok else 'FAIL', 'Calder vs Classic: mean diff %.2f, px diff %d' % (c['mean'], c['big']))
if 'env' in WANTED and pic('env_on') and pic('env_off'):
    env_note = results.get('env_on', {}).get('note', '')
    if 'envlight_notset' in env_note:
        feature['env'] = ('NOT SCRIPTABLE', 'LightType.ENVIRONMENT is not available (see the diagnostics); pictures valid')
    else:
        c = compare(pic('env_on'), pic('env_off'))
        lo, lf = stats(pic('env_on'))['mean_lum'], stats(pic('env_off'))['mean_lum']
        ok = c['mean'] >= 0.5 and c['big'] >= 100 and lo > lf
        feature['env'] = ('OK' if ok else 'FAIL', 'mean diff %.2f, px diff %d, mean lum on %.1f off %.1f'
                          % (c['mean'], c['big'], lo, lf))
if 'stress' in WANTED and pic('stress'):
    s = stats(pic('stress'))
    ok = s['colours'] >= 12 and s['lit'] >= 2000
    feature['stress'] = ('OK' if ok else 'FAIL', 'colours %d, lit px %d' % (s['colours'], s['lit']))

print('')
for scene, tags in SCENE_TAGS:
    if scene not in WANTED:
        continue
    st, txt = feature.get(scene, ('NO RESULT', 'pictures missing'))
    if st in ('FAIL', 'NO RESULT'):
        problems.append('%s feature: %s (%s)' % (scene, st, txt))
    print('feature %-7s %-14s %s' % (scene, st, txt))
for tag in sorted(results):
    if results[tag].get('note'):
        print('note %-13s %s' % (tag, results[tag]['note']))
print('')
print('diagnostics (refusals and property details):')
for d in diags:
    print('  ' + d)
if problems:
    print('SUMMARY FAIL: ' + '; '.join(problems))
    sys.exit(1)
print('SUMMARY PASS')
sys.exit(0)
PY
RC=$?
echo "scene dialogs (dismissed by the test):"
sort "$OUT/dialogs.log" 2> /dev/null | uniq -c | head -n 10
echo "AE windows seen:"
sort -u "$OUT/windows.log" 2> /dev/null | head -n 20
if [ "$RC" -eq 0 ]; then
    echo "PASS: the Advanced 3D scenes render valid pictures and their feature checks pass (files in $OUT)"
else
    echo "FAIL: an Advanced 3D scene failed (files in $OUT)"
fi
exit "$RC"
