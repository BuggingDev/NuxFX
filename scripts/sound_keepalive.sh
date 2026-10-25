#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Keeps the sound output of the Direct3D 12 route's sound server awake while After Effects runs, by playing
# silence.
#
# Why: After Effects opens its audio stream when it starts and uncorks it when a preview starts. The RDP sink
# of that sound server (/mnt/wslg/PulseServer) suspends after 5 idle seconds, and a stream that was created
# corked while it was suspended is not resumed properly: the uncork is answered two seconds late or never,
# and the stream never asks for data. After Effects' audio thread then hangs in waveOutRestart, stopping a
# preview takes a second longer (After Effects ends the thread by force), and the next preview does not
# start. tests/run_pulse_resume_test.sh shows it without Wine and without After Effects. While any other
# stream plays, the sink stays awake and the same sequence works, sound included.
#
#   sound_keepalive.sh [--parent PID]   start the silent stream for as long as process PID lives (default:
#                                       the caller); a second start adds a process to the first one's
#   sound_keepalive.sh --release PID    PID does not need it any more; the stream stops when nobody does
#   sound_keepalive.sh --needed         exit status 0 when this machine's sound server needs it
#   sound_keepalive.sh --check          exit status 0 while the silent stream runs
#   sound_keepalive.sh --stop           stop it now
#
# launch_ae.sh starts and stops it by itself when it is needed (AEGNUX_SOUND_KEEPALIVE=auto, the default;
# 0 never, 1 always). The stream is played by pacat (pulseaudio-utils) when it is installed, otherwise by
# tools/silent_stream.py (python3 and libpulse, which Wine needs for sound anyway).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"
RUN="$AEGNUX_AUDIO_RUN"
PIDFILE="$RUN/keepalive.pid"
USERS="$RUN/keepalive.users"

alive() { kill -0 "$1" 2> /dev/null; }

running() {
    local p
    p=$(cat "$PIDFILE" 2> /dev/null)
    [ -n "$p" ] && alive "$p"
}

# True while a process that asked for the stream still lives.
anyone() {
    local p
    [ -f "$USERS" ] || return 1
    while read -r p; do
        if [ -n "$p" ] && alive "$p"; then return 0; fi
    done < "$USERS"
    return 1
}

# Stops the supervisor and waits until it is gone.
stop_supervisor() {
    local p
    p=$(cat "$PIDFILE" 2> /dev/null)
    if [ -n "$p" ] && alive "$p"; then
        kill "$p" 2> /dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$p" || break; sleep 0.3; done
    fi
    rm -f "$PIDFILE"
}

# Plays the silent stream until it is killed. 8 kHz mono is enough to keep the sink running and costs
# next to nothing.
play() {
    if [ "${AEGNUX_SILENCE_PLAYER:-auto}" != python ] && command -v pacat > /dev/null 2>&1; then
        exec pacat --playback --format=s16le --rate=8000 --channels=1 --latency-msec=100 \
                   --client-name=NuxFX --stream-name="keeps the sound output awake" < /dev/zero
    fi
    exec python3 -I "$HERE/tools/silent_stream.py"
}

# The supervisor: plays silence while anyone needs it and starts the stream again if it ends.
run() {
    local pa=""
    trap 'if [ -n "$pa" ]; then kill "$pa" 2> /dev/null; fi; rm -f "$PIDFILE"; exit 0' TERM INT HUP
    echo $$ > "$PIDFILE"
    while anyone; do
        play > /dev/null 2>&1 &
        pa=$!
        while alive "$pa" && anyone; do
            sleep 2 &
            wait $!
        done
        kill "$pa" 2> /dev/null
        wait "$pa" 2> /dev/null
        pa=""
        if anyone; then sleep 1 & wait $!; fi
    done
    rm -f "$PIDFILE"
}

if [ "${1:-}" = --run ]; then
    run
    exit 0
fi

# start, release and stop do not run at the same time
mkdir -p "$RUN" 2> /dev/null
chmod 700 "$RUN" 2> /dev/null
if command -v flock > /dev/null 2>&1; then
    exec 9> "$RUN/keepalive.lock"
    flock 9
fi

case "${1:-}" in
    --needed)
        [ "$(aegnux_audio_plan)" = keepalive ]
        exit $?
        ;;
    --check)
        running
        exit $?
        ;;
    --stop)
        if running; then
            stop_supervisor
            echo "the silent stream is stopped"
        else
            echo "the silent stream is not running"
        fi
        rm -f "$PIDFILE" "$USERS"
        exit 0
        ;;
    --release)
        if [ -f "$USERS" ] && [ -n "${2:-}" ]; then
            grep -vxF "$2" "$USERS" > "$USERS.new" 2> /dev/null
            mv -f "$USERS.new" "$USERS"
        fi
        if running && ! anyone; then stop_supervisor; fi
        exit 0
        ;;
esac

PARENT=$PPID
if [ "${1:-}" = --parent ]; then PARENT=${2:-$PPID}; fi
if ! aegnux_can_play_silence; then
    echo "neither pacat nor python3 found ($(aegnux_pkg_hint pulseaudio-utils python3))" >&2
    exit 1
fi
aegnux_audio_env
echo "$PARENT" >> "$USERS"
if running; then
    echo "the silent stream already runs (pid $(cat "$PIDFILE"))"
    exit 0
fi
# The supervisor must not hold the lock: it would block the next start and release
( exec 9>&-; setsid nohup "$0" --run > /dev/null 2>&1 & )
for _ in 1 2 3 4 5 6 7 8 9 10; do
    running && break
    sleep 0.3
done
if ! running; then
    echo "the silent stream did not start" >&2
    exit 1
fi
# Wait until the stream plays: an output of the sound server shows RUNNING.
if command -v pactl > /dev/null 2>&1; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if timeout 5 pactl list short sinks 2> /dev/null | grep -q 'RUNNING'; then
            echo "the silent stream plays; the sound output stays awake (pid $(cat "$PIDFILE"))"
            exit 0
        fi
        sleep 0.5
    done
    echo "note: the silent stream started but no output of the sound server shows RUNNING" >&2
fi
exit 0
