#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# A silent audio output for After Effects, from a PulseAudio server of its own. RAM preview works without
# any audio device and with a sound server that works. When the machine's sound server answers but stalls
# once After Effects' audio stream is open (the one of the Direct3D 12 route's display stack did in the
# tests, which ran on a private X server), After Effects' audio thread cannot be stopped in time: stopping
# a preview takes a second longer, After Effects ends the thread by force, and the next preview does not
# start. A silent output of its own does not have that problem.
#
#   null_audio.sh           start the server (nothing happens if it already runs)
#   null_audio.sh --check   exit status 0 when the server runs
#   null_audio.sh --stop    stop the server
#
# The server has no hardware, its socket is $AEGNUX_AUDIO_RUN/native, and it leaves the sound server of the
# desktop alone. After Effects uses it when AEGNUX_NULL_AUDIO=1 (aegnux_env then points PULSE_SERVER at it;
# launch_ae.sh starts and stops the server by itself). It needs the pulseaudio daemon and pactl.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"
R="$AEGNUX_AUDIO_RUN"

# True when the server answers on its own socket.
answers() {
    PULSE_SERVER="unix:$R/native" timeout 5 pactl info > /dev/null 2>&1
}

case "${1:-}" in
    --check)
        command -v pactl > /dev/null 2>&1 && answers
        exit $?
        ;;
    --stop)
        if command -v pactl > /dev/null 2>&1 && answers; then
            PULSE_SERVER="unix:$R/native" pactl exit > /dev/null 2>&1
            echo "the silent audio output is stopped"
        else
            echo "the silent audio output is not running"
        fi
        exit 0
        ;;
esac

for t in pulseaudio pactl; do
    if ! command -v "$t" > /dev/null 2>&1; then
        echo "$t not found ($(aegnux_pkg_hint pulseaudio pulseaudio-utils))" >&2
        exit 1
    fi
done
if answers; then
    echo "the silent audio output already runs ($R/native)"
    exit 0
fi
mkdir -p "$R" "$AEGNUX_LOG_DIR" 2> /dev/null
chmod 700 "$R" 2> /dev/null
# -n: no default.pa, so no hardware modules and no autospawn; the runtime path keeps it apart from the
# server of the desktop. It exits after ten idle minutes.
PULSE_SERVER="" PULSE_RUNTIME_PATH="$R" pulseaudio -n --daemonize=yes --exit-idle-time=600 \
    --log-target="file:$AEGNUX_LOG_DIR/pulseaudio.log" \
    --load="module-native-protocol-unix auth-anonymous=1" \
    --load="module-null-sink sink_name=nuxfx sink_properties=device.description=NuxFX" > /dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
    answers && break
    sleep 1
done
if ! answers; then
    echo "the silent audio output did not start (see $AEGNUX_LOG_DIR/pulseaudio.log)" >&2
    exit 1
fi
echo "silent audio output ready: $R/native (After Effects uses it when AEGNUX_NULL_AUDIO=1)"
