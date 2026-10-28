#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# What a user does with After Effects, end to end: imports files of many formats, evaluates an expression, saves a project and
# opens it again, and renders a comp through the Render Queue into Lossless AVI, H.264 MP4 with AAC, AIFF and (before After
# Effects 26) a TIFF sequence.
# A startup script does the work some time after the start and reports every step in a log file (After Effects allows that
# only with the preference "Allow Scripts to Write Files and Access Network", which ae_prefs.sh sets for this run); the files
# it renders are then read with ffprobe (what the file is, how long it is) and, for the picture formats, ffmpeg (a frame is
# decoded and is not one colour).
# The media files are made with ffmpeg (and ImageMagick for the PSD): PNG, JPEG, TIFF, PSD, EXR, ProRes, HEVC (H.265), H.264 with
# AAC, WAV and MP3. A format that ffmpeg here cannot write is skipped, and so is its import.
# Passes when every step that could run passed. Prints one line per step.
#
# Knobs: AEGNUX_TEST_WAIT (seconds to wait for the end of the script, default 420), AEGNUX_TEST_DELAY (seconds before the script
# starts, default 30), AEGNUX_TEST_DIR (where the rendered files are kept, default $AEGNUX_HOME/tests/features).
# Runs on a private Xvfb display. Needs xdotool, xwininfo, Xvfb, ffmpeg and ffprobe. Any running After Effects of this prefix is
# stopped. The startup script is placed in "$AE_DIR/Scripts/Startup" and removed afterwards.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S="$HERE/../scripts"
. "$S/common.sh"
WAIT="${AEGNUX_TEST_WAIT:-420}"
OUT="${AEGNUX_TEST_DIR:-$AEGNUX_HOME/tests}/features"

for t in xdotool xwininfo Xvfb ffmpeg ffprobe; do
    if ! command -v "$t" > /dev/null; then
        echo "FAIL: $t not installed ($(aegnux_pkg_hint xdotool x11-utils xvfb ffmpeg))"
        exit 1
    fi
done
U=$(aegnux_win_user)
# After Effects 26: the Render Queue cannot write TIFF and Photoshop files (the Photoshop Library says "program error", error
# code 14: its PSLImage has no layer when the writer asks for layer 0). The test leaves that step out there and says so.
case "$(aegnux_ae_version)" in 2[6-9].*|[3-9][0-9].*) WANT_TIFF=0 ;; *) WANT_TIFF=1 ;; esac
USERDIR="$WINEPREFIX/drive_c/users/$U"
MEDIA="$USERDIR/aegnux_media"
RENDER="$USERDIR/aegnux_render"
PLOG="$USERDIR/aegnux_features.log"
JSX="$USERDIR/aegnux_features.jsx"
STARTUP="$AE_DIR/Scripts/Startup/zz_aegnux_features.jsx"

N=99
while [ -e "/tmp/.X$N-lock" ] || grep -q "@/tmp/.X11-unix/X$N\$" /proc/net/unix 2> /dev/null; do N=$((N - 1)); done
Xvfb ":$N" -screen 0 1920x1080x24 -nolisten tcp > /dev/null 2>&1 &
XVFB_PID=$!
export DISPLAY=":$N"
unset WAYLAND_DISPLAY
for _ in $(seq 1 50); do xwininfo -root > /dev/null 2>&1 && break; sleep 0.2; done
xwininfo -root > /dev/null 2>&1 || { echo "FAIL: Xvfb did not start on $DISPLAY"; kill "$XVFB_PID" 2> /dev/null; exit 1; }
cleanup() {
    rm -f "$STARTUP" "$JSX"
    "$S/stop_ae.sh" > /dev/null 2>&1
    kill "$XVFB_PID" 2> /dev/null
    rm -rf "$MEDIA"
}
trap cleanup EXIT

# ---- the media files ----
rm -rf "$MEDIA" "$RENDER" "$OUT"
mkdir -p "$MEDIA" "$RENDER" "$OUT"
rm -f "$PLOG"
FF="ffmpeg -v error -y"
SRC="testsrc2=size=320x180:rate=30"
made=""
mk() { # NAME COMMAND...: makes one file, remembers it when it exists afterwards
    local name=$1; shift
    "$@" > /dev/null 2>&1
    if [ -s "$MEDIA/$name" ]; then made="$made $name"; else echo "note: ffmpeg here cannot make $name; its import is skipped"; fi
}
mk clip_h264.mp4 $FF -f lavfi -i "$SRC" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac "$MEDIA/clip_h264.mp4"
mk clip_hevc.mp4 $FF -f lavfi -i "$SRC" -t 2 -c:v libx265 -pix_fmt yuv420p -tag:v hvc1 "$MEDIA/clip_hevc.mp4"
mk clip_prores.mov $FF -f lavfi -i "$SRC" -t 2 -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$MEDIA/clip_prores.mov"
mk still.png $FF -f lavfi -i "$SRC" -frames:v 1 "$MEDIA/still.png"
mk still.jpg $FF -f lavfi -i "$SRC" -frames:v 1 -q:v 2 "$MEDIA/still.jpg"
mk still.tif $FF -f lavfi -i "$SRC" -frames:v 1 -pix_fmt rgb24 "$MEDIA/still.tif"
mk still.exr $FF -f lavfi -i "$SRC" -frames:v 1 -pix_fmt gbrpf32le "$MEDIA/still.exr"
IM=$(command -v magick || command -v convert || true)
if [ -n "$IM" ] && [ -s "$MEDIA/still.png" ]; then mk still.psd "$IM" "$MEDIA/still.png" "$MEDIA/still.psd"; else echo "note: no ImageMagick, the PSD import is skipped"; fi
mk tone.wav $FF -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 2 -c:a pcm_s16le "$MEDIA/tone.wav"
mk tone.mp3 $FF -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 2 -c:a libmp3lame "$MEDIA/tone.mp3"
echo "media made:$made"

# ---- the startup script ----
printf 'var U = "%s";\nvar MADE = "%s";\nvar WANT_TIFF = %s;\n' "$U" "$made" "$WANT_TIFF" > "$JSX"
cat >> "$JSX" << 'EOF'
// ExtendScript is ECMAScript 3 (no reserved words such as "final", no arrow functions).
var LOG = new File("C:/users/" + U + "/aegnux_features.log");
function log(s) { LOG.open("a"); LOG.writeln(s); LOG.close(); }
function ok(name, good, detail) { log((good ? "ok " : "BAD ") + name + (detail ? " " + detail : "")); }
function clean(s) { return String(s).replace(/[\r\n]+/g, " ").substring(0, 120); }
var base = "C:/users/" + U + "/";
try {
    // 1. imports
    var files = MADE.split(" ");
    for (var i = 0; i < files.length; i++) {
        if (!files[i]) { continue; }
        try {
            var io = new ImportOptions(new File(base + "aegnux_media/" + files[i]));
            var item = app.project.importFile(io);
            var detail = "";
            try { detail = item.width + "x" + item.height + ", " + Math.round(item.duration * 100) / 100 + " s"; } catch (e1) { }
            ok("import " + files[i], !!item, detail);
        } catch (e) { ok("import " + files[i], false, clean(e)); }
    }
    // 2. an expression
    var comp = app.project.items.addComp("features expr", 640, 360, 1.0, 4, 30);
    var solid = comp.layers.addSolid([0.2, 0.5, 0.9], "Box", 100, 100, 1.0);
    var pos = solid.property("ADBE Transform Group").property("ADBE Position");
    pos.expression = "[time * 100, 180 + Math.sin(time * 3) * 50]";
    var v = pos.valueAtTime(2, false);
    var expect = 180 + Math.sin(6) * 50;
    ok("expression", pos.expressionError == "" && Math.abs(v[0] - 200) < 1 && Math.abs(v[1] - expect) < 1,
       "value at 2 s " + Math.round(v[0]) + "," + Math.round(v[1]) + " (expected 200," + Math.round(expect) + "), error: " + clean(pos.expressionError));
    // 3. save and open again
    var items = app.project.numItems;
    var pf = new File(base + "aegnux_render/features.aep");
    app.project.save(pf);
    ok("save", pf.exists, pf.exists ? pf.length + " bytes" : "");
    app.open(pf);
    var found = null;
    for (var k = 1; k <= app.project.numItems; k++) { if (app.project.item(k).name == "features expr") { found = app.project.item(k); } }
    var p2 = found ? found.layer(1).property("ADBE Transform Group").property("ADBE Position") : null;
    ok("open again", !!found && app.project.numItems == items && p2 && p2.expression.indexOf("Math.sin") >= 0,
       app.project.numItems + " of " + items + " items, expression kept: " + (p2 ? (p2.expression.indexOf("Math.sin") >= 0) : "no layer"));
    // 4. the Render Queue
    var rc = found || comp;
    rc.layers.addText("NuxFX");
    // a 2 s tone as an audio layer, so that the H.264 file gets AAC sound and the AIFF file has something to say
    try {
        for (var m = 1; m <= app.project.numItems; m++) { if (app.project.item(m).name == "tone.wav") { rc.layers.add(app.project.item(m)); } }
    } catch (e4) { log("note: no audio layer: " + clean(e4)); }
    var rq = app.project.renderQueue;
    var outs = [
        ["Lossless", "lossless.avi", "Lossless"],
        ["H.264", "h264.mp4", "H.264"],
        ["AIFF", "audio.aif", "AIFF"]
    ];
    if (WANT_TIFF) { outs.push(["TIFF Sequence", "tif_[#####].tif", "TIFF Sequence"]); }
    var queued = [];
    for (var o = 0; o < outs.length; o++) {
        try {
            var rqi = rq.items.add(rc);
            var om = rqi.outputModule(1);
            var tn = null, tl = om.templates;
            for (var t = 0; t < tl.length; t++) { if (String(tl[t]).indexOf(outs[o][2]) == 0 && String(tl[t]).indexOf("_HIDDEN") < 0) { tn = tl[t]; break; } }
            if (!tn) { ok("template " + outs[o][0], false, "no output module template that starts with " + outs[o][2] + " in: " + tl.join(" | ").substring(0, 200)); rqi.remove(); continue; }
            om.applyTemplate(tn);
            om.file = new File(base + "aegnux_render/" + outs[o][1]);
            queued.push(rqi);
            ok("queue " + outs[o][0], true, "template " + tn);
        } catch (e2) { ok("queue " + outs[o][0], false, clean(e2)); }
    }
    rq.render();
    // the queue renders on; check every two seconds until every item has ended
    var waited = 0;
    var finish = function () {
        waited += 2;
        var open = 0;
        for (var q = 0; q < queued.length; q++) {
            var st = queued[q].status;
            if (st == RQItemStatus.RENDERING || st == RQItemStatus.QUEUED || st == RQItemStatus.WILL_CONTINUE || st == RQItemStatus.NEEDS_OUTPUT) { open++; }
        }
        if (open > 0 && waited < 300) { return; }
        for (var r = 0; r < queued.length; r++) { log("queue status " + (r + 1) + " " + queued[r].status + " (done is " + RQItemStatus.DONE + ")"); }
        log("done");
        app.cancelTask(taskId);
    };
    var taskId = app.scheduleTask("(" + finish.toString() + ")()", 2000, true);
} catch (e3) { ok("script", false, clean(e3)); log("done"); }
EOF
printf 'app.scheduleTask("$.evalFile(new File(\x27C:/users/%s/aegnux_features.jsx\x27))", %s, false);\n' "$U" "$(( ${AEGNUX_TEST_DELAY:-30} * 1000 ))" > "$STARTUP"

"$S/stop_ae.sh" > /dev/null 2>&1
"$S/clear_crash_state.sh" > /dev/null
# the script writes its report to a file, which After Effects allows only with this preference
AEGNUX_COACHMARKS=0 AEGNUX_SCRIPT_FILE_ACCESS=1 "$S/ae_prefs.sh" > /dev/null
aegnux_env
cd "$AE_DIR" || exit 1
timeout $((WAIT + 60)) wine AfterFX.exe > "$OUT/wine_out.log" 2> "$OUT/wine_err.log" < /dev/null &
disown $!

T=0
while [ "$T" -lt "$WAIT" ]; do
    grep -q '^done' "$PLOG" 2> /dev/null && break
    sleep 3
    T=$((T + 3))
    # 430x211: "Advanced 3D is not supported" waits for OK. 494x200: "Crash Repair Options". 494x111: error box. 455x221: error box of After Effects 26.
    for X in $(xdotool search --onlyvisible --class afterfx 2> /dev/null); do
        case "$(xwininfo -id "$X" 2> /dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')" in
            430x211|494x200|494x111|455x221) xdotool key --window "$X" Return 2> /dev/null ;;
        esac
    done
    for X in $(xdotool search --onlyvisible --name "System Compatibility Report" 2> /dev/null); do
        xdotool mousemove --window "$X" 437 481 click 1 2> /dev/null
    done
done
sleep 2
if ! grep -q '^done' "$PLOG" 2> /dev/null; then
    echo "FAIL: the startup script did not finish within $WAIT s"
    tr -d '\r' < "$PLOG" 2> /dev/null | tail -n 12
    exit 1
fi
tr -d '\r' < "$PLOG" > "$OUT/report.txt"
cp "$RENDER"/* "$OUT/" 2> /dev/null

BAD=0
STEPS=0
while IFS= read -r line; do
    case "$line" in
        ok\ *) STEPS=$((STEPS + 1)); echo "  $line" ;;
        BAD\ *) STEPS=$((STEPS + 1)); BAD=$((BAD + 1)); echo "  $line" ;;
    esac
done < "$OUT/report.txt"

# ---- the rendered files ----
check() { # NAME DESCRIPTION CONDITION...: prints one line, counts a failure
    local name=$1 desc=$2; shift 2
    STEPS=$((STEPS + 1))
    if "$@"; then echo "  ok file $name: $desc"; else echo "  BAD file $name: $desc"; BAD=$((BAD + 1)); fi
}
fdur() { ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2> /dev/null | head -n 1 | cut -d. -f1; }
fcodecs() { ffprobe -v error -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2> /dev/null | tr '\n' ' '; }
fframes() { ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$1" 2> /dev/null | head -n 1; }
has_codec() { fcodecs "$1" | grep -qw "$2"; }
at_least() { [ "${1:-0}" -ge "$2" ] 2> /dev/null; }
real_picture() { # FILE: the first frame, scaled to 16x9 grey values, has more than 4 different values
    local n
    n=$(ffmpeg -v error -i "$1" -frames:v 1 -vf "scale=16:9" -f rawvideo -pix_fmt gray - 2> /dev/null | od -An -tu1 -v | tr -s ' ' '\n' | grep . | sort -u | wc -l)
    [ "$n" -gt 4 ]
}
# the comp is 4 s at 30 fps: 120 frames; its audio layer is a 2 s tone
if [ -f "$OUT/lossless.avi" ]; then
    check lossless.avi "$(fcodecs "$OUT/lossless.avi"), $(fframes "$OUT/lossless.avi") frames" at_least "$(fframes "$OUT/lossless.avi")" 110
    check lossless.avi "a frame is not one colour" real_picture "$OUT/lossless.avi"
else check lossless.avi "was not rendered" false; fi
if [ -f "$OUT/h264.mp4" ]; then
    check h264.mp4 "streams: $(fcodecs "$OUT/h264.mp4")" has_codec "$OUT/h264.mp4" h264
    check h264.mp4 "has AAC sound" has_codec "$OUT/h264.mp4" aac
    check h264.mp4 "$(fdur "$OUT/h264.mp4") s long (the comp is 4 s), $(fframes "$OUT/h264.mp4") frames" at_least "$(fframes "$OUT/h264.mp4")" 110
    check h264.mp4 "a frame is not one colour" real_picture "$OUT/h264.mp4"
else check h264.mp4 "was not rendered" false; fi
if [ -f "$OUT/audio.aif" ]; then
    check audio.aif "streams: $(fcodecs "$OUT/audio.aif"), $(fdur "$OUT/audio.aif") s long" at_least "$(fdur "$OUT/audio.aif")" 3
else check audio.aif "was not rendered" false; fi
NT=$(ls "$OUT"/tif_*.tif 2> /dev/null | wc -l)
if [ "$WANT_TIFF" = 0 ]; then
    echo "  note: the TIFF sequence is not rendered with After Effects $(aegnux_ae_version) (known issue: the Photoshop Library fails, see docs/known-issues.md)"
elif [ "$NT" -gt 0 ]; then
    check "tif_#####.tif" "$NT frames" at_least "$NT" 110
    check "tif_#####.tif" "a frame is not one colour" real_picture "$(ls "$OUT"/tif_*.tif | head -n 1)"
else check "tif_#####.tif" "was not rendered" false; fi
if [ "$BAD" -eq 0 ]; then
    echo "PASS: $STEPS steps (files in $OUT)"
    exit 0
fi
echo "FAIL: $BAD of $STEPS steps failed (report: $OUT/report.txt, Wine log: $OUT/wine_err.log)"
exit 1
