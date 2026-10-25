#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
"""Plays silence on the default output of the PulseAudio or PipeWire server (PULSE_SERVER, else the default one)
until it is killed. scripts/sound_keepalive.sh uses it when pacat is not installed: the stream keeps the sound
output awake, which the sound server of the Direct3D 12 route needs while After Effects runs (see that script).

It starts nothing else: PA_CONTEXT_NOAUTOSPAWN keeps libpulse from launching a sound server. Exit status 1 when
the server goes away, so the caller can start it again, 2 when there is no server or no output.
"""
import ctypes
import sys
import time

try:
    pa = ctypes.CDLL('libpulse.so.0')
except OSError:
    sys.exit(2)

vp = ctypes.c_void_p


def sig(name, restype, *argtypes):
    f = getattr(pa, name)
    f.restype = restype
    f.argtypes = list(argtypes)


sig('pa_threaded_mainloop_new', vp)
sig('pa_threaded_mainloop_get_api', vp, vp)
sig('pa_threaded_mainloop_start', ctypes.c_int, vp)
sig('pa_threaded_mainloop_lock', None, vp)
sig('pa_threaded_mainloop_unlock', None, vp)
sig('pa_context_new', vp, vp, ctypes.c_char_p)
sig('pa_context_connect', ctypes.c_int, vp, ctypes.c_char_p, ctypes.c_int, vp)
sig('pa_context_get_state', ctypes.c_int, vp)
sig('pa_stream_new', vp, vp, ctypes.c_char_p, vp, vp)
sig('pa_stream_connect_playback', ctypes.c_int, vp, ctypes.c_char_p, vp, ctypes.c_int, vp, vp)
sig('pa_stream_get_state', ctypes.c_int, vp)
sig('pa_stream_writable_size', ctypes.c_size_t, vp)
sig('pa_stream_write', ctypes.c_int, vp, ctypes.c_char_p, ctypes.c_size_t, vp, ctypes.c_int64, ctypes.c_int)


class SampleSpec(ctypes.Structure):
    _fields_ = [('format', ctypes.c_int), ('rate', ctypes.c_uint32), ('channels', ctypes.c_uint8)]


class BufferAttr(ctypes.Structure):
    _fields_ = [('maxlength', ctypes.c_uint32), ('tlength', ctypes.c_uint32), ('prebuf', ctypes.c_uint32),
                ('minreq', ctypes.c_uint32), ('fragsize', ctypes.c_uint32)]


RATE = 8000
ml = pa.pa_threaded_mainloop_new()
pa.pa_threaded_mainloop_start(ml)
pa.pa_threaded_mainloop_lock(ml)


def pause(seconds):
    pa.pa_threaded_mainloop_unlock(ml)
    time.sleep(seconds)
    pa.pa_threaded_mainloop_lock(ml)


ctx = pa.pa_context_new(pa.pa_threaded_mainloop_get_api(ml), b'NuxFX')
pa.pa_context_connect(ctx, None, 1, None)   # PA_CONTEXT_NOAUTOSPAWN
t0 = time.time()
while pa.pa_context_get_state(ctx) not in (4, 5, 6) and time.time() - t0 < 5:
    pause(0.01)
if pa.pa_context_get_state(ctx) != 4:
    sys.exit(2)

ss = SampleSpec(3, RATE, 1)   # PA_SAMPLE_S16LE, mono
attr = BufferAttr(0xffffffff, RATE * 2 // 10, 0xffffffff, 0xffffffff, 0xffffffff)   # 100 ms, the rest server's choice
stream = pa.pa_stream_new(ctx, b'keeps the sound output awake', ctypes.byref(ss), None)
rc = pa.pa_stream_connect_playback(stream, None, ctypes.byref(attr), 0x2000, None, None)   # ADJUST_LATENCY
t0 = time.time()
while rc == 0 and pa.pa_stream_get_state(stream) not in (2, 3, 4) and time.time() - t0 < 5:
    pause(0.01)
if rc != 0 or pa.pa_stream_get_state(stream) != 2:
    sys.exit(2)

zeros = bytes(RATE * 2)
while pa.pa_context_get_state(ctx) == 4 and pa.pa_stream_get_state(stream) == 2:
    w = pa.pa_stream_writable_size(stream)
    if w and w != 0xffffffffffffffff:
        pa.pa_stream_write(stream, zeros, min(w, len(zeros)), None, 0, 0)
    pause(0.05)
sys.exit(1)
