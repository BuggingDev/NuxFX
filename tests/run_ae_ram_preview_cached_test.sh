#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# The classic RAM preview: After Effects renders the whole range into RAM first ("Cache Before Playback", what the
# numpad-0 shortcut does in a default setup) and then plays it from the cache in real time, with its audio. Same
# measurements and pass criteria as run_ae_ram_preview_test.sh, which plays with the Space shortcut as it is
# (it caches while it plays). The numpad-0 key itself cannot be sent on a bare Xvfb display (no NumLock), so the
# run switches the option on for the Space shortcut and puts it back afterwards (AEGNUX_RP_CACHE_FIRST=1).
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export AEGNUX_RP_CACHE_FIRST=1
exec "$HERE/run_ae_ram_preview_test.sh" "$@"
