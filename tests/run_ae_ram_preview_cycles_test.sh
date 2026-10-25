#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# Starts and stops a RAM preview three times in one After Effects session (AEGNUX_RP_CYCLES changes the
# number). A cycle passes if the preview starts and, after the key that stops it, the red needle is gone
# and the blue playhead has moved to the frame where the preview stopped. The sound server of the Direct3D 12
# route breaks it unless a silent stream keeps its output awake (scripts/sound_keepalive.sh): the first stop takes a second
# longer and the next preview does not start. By default the test gives After Effects the audio output that
# launch_ae.sh gives it; AEGNUX_TEST_AUDIO=host leaves the machine's sound server as it is and fails on such a
# server. The setup, the knobs and the prerequisites are those of run_ae_ram_preview_test.sh.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export AEGNUX_RP_CYCLES="${AEGNUX_RP_CYCLES:-3}"
exec "$HERE/run_ae_ram_preview_test.sh" "$@"
