#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# RAM preview under heavy memory use: a 3840x2160, 120 s comp (119 GB of frames at full size) is previewed for
# four minutes, so the RAM cache grows until After Effects' own limit. The test passes if After Effects stays
# alive, the machine keeps AEGNUX_RP_MIN_AVAILABLE_MB (default 2500) free, and the preview plays at about real
# time. The red needle is reported but does not count: in a preview this long it can stop (AEGNUX_RP_NEEDLE_CHECK=1
# makes it count). It reports how much memory After Effects and Wine held at most and the
# highest number of memory mappings (the "need to tweak your system config" of AEGNUX is vm.max_map_count).
# Same setup, knobs and prerequisites as run_ae_ram_preview_test.sh. It needs about 12 GB of available memory
# (SKIP below AEGNUX_RP_HEAVY_MIN_MB) and takes about 7 minutes.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEED="${AEGNUX_RP_HEAVY_MIN_MB:-12000}"
AVAIL=$(awk '/MemAvailable/{print int($2 / 1024)}' /proc/meminfo)
if [ "$AVAIL" -lt "$NEED" ]; then
    echo "SKIP: this test needs about $NEED MB of available memory, the machine has $AVAIL MB"
    exit 0
fi
export AEGNUX_RP_COMP="${AEGNUX_RP_COMP:-3840x2160x120}"
export AEGNUX_RP_SECONDS="${AEGNUX_RP_SECONDS:-240}"
export AEGNUX_RP_MEMWATCH=1
export AEGNUX_RP_NEEDLE_CHECK="${AEGNUX_RP_NEEDLE_CHECK:-0}"
exec "$HERE/run_ae_ram_preview_test.sh" "$@"
