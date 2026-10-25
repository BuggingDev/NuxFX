#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Checks that a new text layer in After Effects gets a font that has letters. A startup script makes
# a comp and a text layer with the default font (the script cannot name one) and measures the box of
# the text with sourceRectAtTime; a font without Latin letters measures 0 x 0. The test passes if
# the box is at least 100 x 50 pixels at font size 200.
#
# Why: After Effects' default font is Myriad Pro. When Wine did not have it, After Effects took
# NotoSansSignWriting on a machine with the Noto fonts, and every new text layer looked empty.
# scripts/ae_prefs.sh copies Myriad Pro from After Effects' own pdfl/Fonts folder into the prefix.
#
# Runs on a private Xvfb display (nothing appears on the desktop). Requires xdotool, xwininfo and
# Xvfb. The startup script is placed in "$AE_DIR/Scripts/Startup" and removed afterwards. Any
# running After Effects of this prefix is stopped. About 1.5 minutes.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S="$HERE/../scripts"
. "$S/common.sh"
WAIT="${AEGNUX_TEST_WAIT:-150}"

for t in xdotool xwininfo Xvfb; do
    if ! command -v "$t" > /dev/null; then
        echo "FAIL: $t not installed ($(aegnux_pkg_hint xdotool x11-utils xvfb))"
        exit 1
    fi
done
U=$(aegnux_win_user)
USERDIR="$WINEPREFIX/drive_c/users/$U"
PLOG="$USERDIR/aegnux_text_test.log"
JSX="$USERDIR/aegnux_text_test.jsx"
STARTUP="$AE_DIR/Scripts/Startup/zz_aegnux_text_test.jsx"

# Abstract X sockets of servers that run in another mount namespace but share this network
# namespace (containers, other distributions) count as taken too (/proc/net/unix lists them).
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
}
trap cleanup EXIT

rm -f "$PLOG"
cat > "$JSX" << 'EOF'
var LOG = new File("C:/users/" + $.getenv("USERNAME") + "/aegnux_text_test.log");
function log(s) { LOG.open("a"); LOG.writeln(s); LOG.close(); }
try {
    var n = -1;
    try { n = app.fonts.allFonts.length; } catch (e0) { }
    log("font families seen by After Effects: " + n);
    var comp = app.project.items.addComp("aegnux text test", 1280, 720, 1.0, 2, 30);
    var layer = comp.layers.addText("LINUX");
    var doc = layer.property("ADBE Text Properties").property("ADBE Text Document");
    var v = doc.value;
    v.fontSize = 200;
    doc.setValue(v);
    var r = layer.sourceRectAtTime(0, false);
    log("default font " + doc.value.font + " box " + Math.round(r.width) + " " + Math.round(r.height));
} catch (e) { log("error " + e); }
log("done");
EOF
printf 'app.scheduleTask("$.evalFile(new File(\x27C:/users/%s/aegnux_text_test.jsx\x27))", %s, false);\n' "$U" "$(( ${AEGNUX_TEST_DELAY:-30} * 1000 ))" > "$STARTUP"

"$S/stop_ae.sh" > /dev/null 2>&1
"$S/clear_crash_state.sh" > /dev/null
# the script writes its result to a file, which After Effects allows only with this preference
AEGNUX_COACHMARKS=0 AEGNUX_SCRIPT_FILE_ACCESS=1 "$S/ae_prefs.sh" > /dev/null
aegnux_env
cd "$AE_DIR" || exit 1
timeout $((WAIT + 30)) wine AfterFX.exe > /dev/null 2> /dev/null < /dev/null &
disown $!

T=0
while [ "$T" -lt "$WAIT" ]; do
    grep -q '^done' "$PLOG" 2> /dev/null && break
    sleep 3
    T=$((T + 3))
    # 430x211: "Advanced 3D is not supported" waits for OK. 494x200: "Crash Repair Options".
    for X in $(xdotool search --onlyvisible --class afterfx 2> /dev/null); do
        case "$(xwininfo -id "$X" 2> /dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')" in
            430x211|494x200) xdotool key --window "$X" Return 2> /dev/null ;;
        esac
    done
done

if ! grep -q '^done' "$PLOG" 2> /dev/null; then
    echo "FAIL: the startup script did not finish within $WAIT s"
    exit 1
fi
# The log has the Windows line ending.
tr -d '\r' < "$PLOG" > "$PLOG.txt"
cat "$PLOG.txt"
LINE=$(sed -n 's/^default font \(.*\) box \([0-9]*\) \([0-9]*\)$/\1 \2 \3/p' "$PLOG.txt" | head -n 1)
rm -f "$PLOG.txt"
if [ -z "$LINE" ]; then
    echo "FAIL: the text layer could not be measured (see the lines above)"
    exit 1
fi
read -r FONT W H <<< "$LINE"
if [ "$W" -ge 100 ] && [ "$H" -ge 50 ]; then
    echo "PASS: a new text layer gets the font $FONT, its text box is ${W}x${H} pixels"
else
    echo "FAIL: a new text layer gets the font $FONT and its text box is ${W}x${H}: the font has no letters for the text (is Myriad Pro in the prefix? scripts/doctor.sh says)"
    exit 1
fi
