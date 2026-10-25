#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
"""Replays the stream sequence of Wine's PulseAudio driver (which is what After Effects' audio goes through)
against the sound server that PULSE_SERVER names (or the default one), without Wine and without After Effects:

  create a stream corked and prefill it, then three times:  uncork, feed it for a few seconds, cork, stay idle
  long enough for the server to suspend the output (module-suspend-on-idle waits 5 s)

A server that works answers every cork and uncork at once and asks for data all the time. The RDP sink of the
Direct3D 12 route's sound server does for the first round only: after the idle time the uncork is answered two seconds late or never, and the stream
stops asking for data. After Effects' audio thread then hangs, and RAM preview breaks (docs/troubleshooting.md).

usage: pulse_resume_test.py [ROUNDS [IDLE_SECONDS]]
exit status: 0 every round worked, 1 a round stalled, 2 no sound server or no output to play on
"""
import ctypes
import sys
import time

ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 3
IDLE = float(sys.argv[2]) if len(sys.argv) > 2 else 7.0
PLAY = 3.0          # seconds of feeding per round
RATE = 44100        # what Wine's mix format is on the RDP sink
FRAME = 8           # float32 stereo
ANSWER_LIMIT = 1.0  # a cork or uncork that takes longer than this is a stall

try:
    pa = ctypes.CDLL('libpulse.so.0')
except OSError:
    print('SKIP: libpulse.so.0 is not installed')
    sys.exit(2)

vp = ctypes.c_void_p
OPCB = ctypes.CFUNCTYPE(None, vp, ctypes.c_int, vp)


def sig(name, restype, *argtypes):
    f = getattr(pa, name)
    f.restype = restype
    f.argtypes = list(argtypes)


sig('pa_threaded_mainloop_new', vp)
sig('pa_threaded_mainloop_get_api', vp, vp)
sig('pa_threaded_mainloop_start', ctypes.c_int, vp)
sig('pa_threaded_mainloop_stop', None, vp)
sig('pa_threaded_mainloop_lock', None, vp)
sig('pa_threaded_mainloop_unlock', None, vp)
sig('pa_context_new', vp, vp, ctypes.c_char_p)
sig('pa_context_connect', ctypes.c_int, vp, ctypes.c_char_p, ctypes.c_int, vp)
sig('pa_context_get_state', ctypes.c_int, vp)
sig('pa_context_disconnect', None, vp)
sig('pa_stream_new', vp, vp, ctypes.c_char_p, vp, vp)
sig('pa_stream_connect_playback', ctypes.c_int, vp, ctypes.c_char_p, vp, ctypes.c_int, vp, vp)
sig('pa_stream_get_state', ctypes.c_int, vp)
sig('pa_stream_writable_size', ctypes.c_size_t, vp)
sig('pa_stream_write', ctypes.c_int, vp, ctypes.c_char_p, ctypes.c_size_t, vp, ctypes.c_int64, ctypes.c_int)
sig('pa_stream_cork', vp, vp, ctypes.c_int, OPCB, vp)
sig('pa_stream_disconnect', ctypes.c_int, vp)
sig('pa_operation_get_state', ctypes.c_int, vp)


class SampleSpec(ctypes.Structure):
    _fields_ = [('format', ctypes.c_int), ('rate', ctypes.c_uint32), ('channels', ctypes.c_uint8)]


class BufferAttr(ctypes.Structure):
    _fields_ = [('maxlength', ctypes.c_uint32), ('tlength', ctypes.c_uint32), ('prebuf', ctypes.c_uint32),
                ('minreq', ctypes.c_uint32), ('fragsize', ctypes.c_uint32)]


ml = pa.pa_threaded_mainloop_new()
pa.pa_threaded_mainloop_start(ml)
pa.pa_threaded_mainloop_lock(ml)


def pause(seconds):
    """Let the server's answers arrive while the lock is free."""
    pa.pa_threaded_mainloop_unlock(ml)
    time.sleep(seconds)
    pa.pa_threaded_mainloop_lock(ml)


def finish(code, text):
    print(text)
    sys.stdout.flush()
    sys.exit(code)


ctx = pa.pa_context_new(pa.pa_threaded_mainloop_get_api(ml), b'NuxFX pulse resume test')
pa.pa_context_connect(ctx, None, 1, None)   # PA_CONTEXT_NOAUTOSPAWN: never start a sound server for the test
t0 = time.time()
while pa.pa_context_get_state(ctx) not in (4, 5, 6) and time.time() - t0 < 5:
    pause(0.01)
if pa.pa_context_get_state(ctx) != 4:
    finish(2, 'SKIP: no sound server answers')

ss = SampleSpec(5, RATE, 2)   # PA_SAMPLE_FLOAT32LE
attr = BufferAttr(RATE * FRAME // 10, RATE * FRAME * 25 // 1000, 8, RATE * FRAME * 10 // 1000, RATE * FRAME * 10 // 1000)
stream = pa.pa_stream_new(ctx, b'After Effects like stream', ctypes.byref(ss), None)
# START_CORKED | START_UNMUTED | AUTO_TIMING_UPDATE | INTERPOLATE_TIMING | ADJUST_LATENCY, as Wine's driver does
rc = pa.pa_stream_connect_playback(stream, None, ctypes.byref(attr), 0x1 | 0x10000 | 0x8 | 0x2 | 0x2000, None, None)
t0 = time.time()
while rc == 0 and pa.pa_stream_get_state(stream) not in (2, 3, 4) and time.time() - t0 < 5:
    pause(0.01)
if rc != 0 or pa.pa_stream_get_state(stream) != 2:
    finish(2, 'SKIP: the sound server has no output to play on')

noop = OPCB(lambda s, ok, u: None)
zeros = bytes(65536)


def wait_op(op, limit):
    """Seconds until the server answered, or None."""
    t = time.time()
    while pa.pa_operation_get_state(op) == 0:
        pause(0.002)
        if time.time() - t > limit:
            return None
    return time.time() - t


def cork(flag):
    return wait_op(pa.pa_stream_cork(stream, flag, noop, None), 8)


bad = 0
pa.pa_stream_write(stream, zeros, attr.tlength, None, 0, 0)
for rnd in range(1, ROUNDS + 1):
    d = cork(0)
    if d is None:
        print('round %d: uncork: no answer in 8 s' % rnd)
        bad += 1
        break
    ok = d <= ANSWER_LIMIT
    written = 0
    end = time.time() + PLAY
    while time.time() < end:
        w = pa.pa_stream_writable_size(stream)
        if w and w != 0xffffffffffffffff:
            n = min(w, len(zeros))
            pa.pa_stream_write(stream, zeros, n, None, 0, 0)
            written += n
        pause(0.01)
    expected = RATE * FRAME * PLAY
    fed = written >= 0.5 * expected
    print('round %d: uncork answered in %.3f s, the stream took %d%% of the data it should: %s' % (
        rnd, d, 100 * written // expected, 'ok' if ok and fed else 'STALLED'))
    if not (ok and fed):
        bad += 1
    d = cork(1)
    if d is None or d > ANSWER_LIMIT:
        print('round %d: cork %s' % (rnd, 'no answer in 8 s' if d is None else 'answered in %.3f s: STALLED' % d))
        bad += 1
        if d is None:
            break
    if rnd < ROUNDS:
        pause(IDLE)

pa.pa_stream_disconnect(stream)
pa.pa_context_disconnect(ctx)
pa.pa_threaded_mainloop_unlock(ml)
finish(1 if bad else 0, 'stalled' if bad else 'every round worked')
