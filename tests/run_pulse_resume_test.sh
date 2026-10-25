#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Does the machine's sound server resume a stream that was created corked, after its output went idle and
# suspended? That is the sequence of Wine's PulseAudio driver, so of After Effects' audio. No Wine and no
# After Effects are started; it takes about half a minute and plays only silence.
#
# The sound server of the Direct3D 12 route's display stack (its output is an RDP sink) fails it: the uncork of the second
# round is answered two seconds late or never and the stream stops asking for data (docs/troubleshooting.md). That
# is not a failure of the setup: scripts/sound_keepalive.sh plays a silent stream so the sink never suspends,
# and the test then runs the same sequence again with it. It fails only if the sequence breaks with
# the silent stream as well, or if the server needs it and nothing can play it (no pacat and no python3).
# Passes (exit 0) also when there is no sound server: After Effects then has no audio device, which works.
# Needs python3 and libpulse.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S="$HERE/../scripts"
. "$S/common.sh"
aegnux_audio_env
command -v python3 > /dev/null 2>&1 || { echo "FAIL: python3 is not installed ($(aegnux_pkg_hint python3))"; exit 1; }
STARTED=0
cleanup() { [ "$STARTED" = 1 ] && "$S/sound_keepalive.sh" --release "$$" > /dev/null 2>&1; return 0; }
trap cleanup EXIT

echo "sound server: ${PULSE_SERVER:-default}"
python3 -I "$HERE/pulse_resume_test.py" 3 7
RC=$?
case "$RC" in
    0)
        echo "PASS: the sound server resumes a stream that was created corked, also after its output suspended"
        exit 0
        ;;
    2)
        echo "PASS: there is no sound server to test (After Effects then runs without an audio device)"
        exit 0
        ;;
esac
echo "The sound server does not resume a stream that was created corked after its output suspended (the RDP sink of the Direct3D 12 route does this)."
if ! aegnux_sound_sink_is_rdp; then
    echo "FAIL: the output is not an RDP sink, so scripts/sound_keepalive.sh is not used here; After Effects' audio will hang on this server"
    exit 1
fi
if ! aegnux_can_play_silence; then
    echo "FAIL: neither pacat nor python3 is installed, so the silent stream cannot be played ($(aegnux_pkg_hint python3 pulseaudio-utils))"
    exit 1
fi
echo "Again, with the silent stream of scripts/sound_keepalive.sh playing:"
"$S/sound_keepalive.sh" --parent "$$" || { echo "FAIL: the silent stream did not start"; exit 1; }
STARTED=1
python3 -I "$HERE/pulse_resume_test.py" 3 7
RC=$?
if [ "$RC" = 0 ]; then
    echo "PASS: with the silent stream the same sequence works (launch_ae.sh plays it while After Effects runs)"
    exit 0
fi
echo "FAIL: the sequence breaks with the silent stream as well"
exit 1
