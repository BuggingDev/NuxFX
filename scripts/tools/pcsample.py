#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
"""PC sampler for one thread via ptrace, with a closer look at samples inside libc.

usage: sudo pcsample.py PID TID SECONDS

For samples whose instruction pointer is in libc.so.6 (outside a syscall) it records
the caller (first return-address-like stack word that points into other executable
code), the mappings behind rdi and rsi (the usual dst/src of memcpy and memset), and
the hot libc offsets. Adobe PE images are reported as module names only.
"""
import bisect
import collections
import ctypes
import os
import random
import re
import signal
import subprocess
import sys
import time

PTRACE_PEEKDATA, PTRACE_CONT, PTRACE_GETREGS, PTRACE_ATTACH, PTRACE_DETACH = 2, 7, 12, 16, 17
WALL = 0x40000000

libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.restype = ctypes.c_long
libc.ptrace.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]


class Regs(ctypes.Structure):
    _fields_ = [(n, ctypes.c_ulonglong) for n in (
        "r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi orig_rax "
        "rip cs eflags rsp ss fs_base gs_base ds es fs gs").split()]


pid, tid, secs = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
M64 = 0xFFFFFFFFFFFFFFFF


def wait_stop():
    _, st = os.waitpid(tid, WALL)
    return os.WSTOPSIG(st) if os.WIFSTOPPED(st) else None


def read_maps():
    out = []
    for line in open("/proc/%d/maps" % pid):
        m = re.match(r"([0-9a-f]+)-([0-9a-f]+) (\S+) ([0-9a-f]+) \S+ \d+\s*(.*)", line)
        if m:
            out.append((int(m[1], 16), int(m[2], 16), m[3], int(m[4], 16), m[5]))
    return out


maps = read_maps()
starts = [m[0] for m in maps]


def lib_of(addr):
    i = bisect.bisect_right(starts, addr) - 1
    if i >= 0 and addr < maps[i][1]:
        return maps[i]
    return None


def peek(addr):
    ctypes.set_errno(0)
    v = libc.ptrace(PTRACE_PEEKDATA, tid, ctypes.c_void_p(addr), None)
    if v == -1 and ctypes.get_errno():
        return None
    return v & M64


def bucket(n):
    return "0" if n == 0 else "2^%d" % (n.bit_length() - 1)


if libc.ptrace(PTRACE_ATTACH, tid, None, None) != 0:
    sys.exit("ptrace attach failed: errno %d" % ctypes.get_errno())
wait_stop()

def thread_stat():
    f = open("/proc/%d/task/%d/stat" % (pid, tid)).read().rsplit(")", 1)[1].split()
    # fields after the comm: state is f[0]; minflt f[7], majflt f[9], utime f[11], stime f[12]
    return int(f[7]), int(f[9]), int(f[11]), int(f[12])


def zero_maps():
    n = tot = 0
    for m in maps:
        if "zero (deleted)" in m[4]:
            n += 1
            tot += m[1] - m[0]
    return n, tot


regs = Regs()
samples = []          # (rip, in_syscall)
hot = []              # details of samples inside libc.so.6
dst_maps, src_maps = [], []
hot_stack = []
stat0 = thread_stat()
zero_seen = set()
zero_counts = []
last_maps = time.time()
t_end = time.time() + secs
while time.time() < t_end:
    libc.ptrace(PTRACE_GETREGS, tid, None, ctypes.byref(regs))
    insys = regs.orig_rax != M64
    samples.append((regs.rip, insys))
    if time.time() - last_maps > 0.5:
        maps = read_maps()
        starts = [m[0] for m in maps]
        last_maps = time.time()
        zero_counts.append(zero_maps())
        zero_seen.update((m[0], m[1]) for m in maps if "zero (deleted)" in m[4])
    m = lib_of(regs.rip)
    if m and not insys and m[4].endswith("libc.so.6"):
        caller = None
        for k in range(0, 24):
            w = peek(regs.rsp + 8 * k)
            mm = lib_of(w) if w else None
            if mm and "x" in mm[2] and mm[4] and not mm[4].endswith("libc.so.6"):
                caller = (mm[4], w)
                break
        d, s = lib_of(regs.rdi), lib_of(regs.rsi)
        hot.append((regs.rip - (m[0] - m[3]), caller,
                    os.path.basename(d[4]) if d and d[4] else ("[anon]" if d else "unmapped"),
                    os.path.basename(s[4]) if s and s[4] else ("[anon]" if s else "unmapped"),
                    regs.rdx, regs.rcx))
        dst_maps.append((d[0], d[1] - d[0]) if d else (0, 0))
        src_maps.append((s[0], s[1] - s[0]) if s else (0, 0))
        hot_stack.append([w for w in (peek(regs.rsp + 8 * k) for k in range(64))
                          if w and lib_of(w) and "x" in lib_of(w)[2] and lib_of(w)[4]
                          and not lib_of(w)[4].endswith("libc.so.6")])
    libc.ptrace(PTRACE_CONT, tid, None, None)
    time.sleep(random.uniform(0.002, 0.006))
    libc.syscall(234, pid, tid, signal.SIGSTOP)      # tgkill
    while True:
        sg = wait_stop()
        if sg is None or sg == signal.SIGSTOP:
            break
        libc.ptrace(PTRACE_CONT, tid, None, ctypes.c_void_p(sg))
    if sg is None:
        break
libc.ptrace(PTRACE_DETACH, tid, None, None)
stat1 = thread_stat()

maps = read_maps()
starts = [m[0] for m in maps]
bases = {}
for start, end, perms, off, path in maps:
    if path and off == 0 and path not in bases:
        bases[path] = start

syms = {}


def load_syms(path):
    if path in syms:
        return syms[path]
    found = []
    for flags in (["-n", "--defined-only"], ["-D", "-n", "--defined-only"]):
        try:
            out = subprocess.run(["nm"] + flags + [path], capture_output=True, text=True,
                                 timeout=120).stdout
        except Exception:
            continue
        for line in out.splitlines():
            p = line.split()
            if len(p) == 3 and p[1] in "tTwWiI":
                found.append((int(p[0], 16), p[2]))
        if found:
            break
    found.sort()
    syms[path] = (found, [a for a, _ in found])
    return syms[path]


def sym_of(path, addr):
    base = bases.get(path)
    if base is None or not (path.endswith(".so") or ".so." in path):
        return ""
    found, addrs = load_syms(path)
    j = bisect.bisect_right(addrs, addr - base) - 1
    return found[j][1] if j >= 0 else "+0x%x" % (addr - base)


n = len(samples)
n_sys = sum(1 for _, s in samples if s)
by_mod = collections.Counter()
for rip, insys in samples:
    m = lib_of(rip)
    by_mod[os.path.basename(m[4]) if m and m[4] else "[anon]"] += 1
print("%d samples in %.1f s; %d in a syscall (%.0f %%)" % (n, secs, n_sys, 100.0 * n_sys / max(n, 1)))
print("thread: minor faults %d/s, major faults %d/s, user %.0f %%, system %.0f %% (of one CPU)" % (
    (stat1[0] - stat0[0]) / secs, (stat1[1] - stat0[1]) / secs,
    (stat1[2] - stat0[2]) / secs, (stat1[3] - stat0[3]) / secs))
if zero_counts:
    print("'zero (deleted)' mappings: %d..%d at a time (%d..%d MB), %d distinct (start,end) seen in %d snapshots" % (
        min(c[0] for c in zero_counts), max(c[0] for c in zero_counts),
        min(c[1] for c in zero_counts) >> 20, max(c[1] for c in zero_counts) >> 20,
        len(zero_seen), len(zero_counts)))
if dst_maps:
    for name, lst in (("dst", dst_maps), ("src", src_maps)):
        c = collections.Counter(lst)
        print("%s mappings of hot samples: %d distinct; top: %s" % (
            name, len(c), ", ".join("0x%x+%dKB x%d" % (a, sz >> 10, k) for (a, sz), k in c.most_common(4))))
print("--- all samples by module:")
for k, v in by_mod.most_common(10):
    print("%6.1f %%  %s" % (100.0 * v / n, k))

nh = len(hot)
print("--- %d samples (%.0f %%) in libc.so.6 outside syscalls" % (nh, 100.0 * nh / max(n, 1)))
if nh:
    print("hot libc offsets:")
    for off, v in collections.Counter(h[0] for h in hot).most_common(6):
        print("  %5.1f %%  libc+0x%x" % (100.0 * v / nh, off))
    print("callers (first non-libc code address on the stack):")
    cal = collections.Counter()
    for h in hot:
        if h[1]:
            path, addr = h[1]
            base = bases.get(path, 0)
            cal["%s : %s (+0x%x)" % (os.path.basename(path), sym_of(path, addr), addr - base)] += 1
        else:
            cal["(none found)"] += 1
    for k, v in cal.most_common(10):
        print("  %5.1f %%  %s" % (100.0 * v / nh, k))
    print("functions found on the stack of the hot samples (return addresses, stale words included):")
    fr = collections.Counter()
    for words in hot_stack:
        seen = set()
        for w in words:
            m = lib_of(w)
            if m:
                seen.add("%s : %s" % (os.path.basename(m[4]), sym_of(m[4], w) or "(pe code)"))
        fr.update(seen)
    for k, v in fr.most_common(22):
        print("  %5.1f %%  %s" % (100.0 * v / nh, k))
    print("dst / src mappings (rdi / rsi):")
    for (d, s), v in collections.Counter((h[2], h[3]) for h in hot).most_common(8):
        print("  %5.1f %%  %s <- %s" % (100.0 * v / nh, d, s))
    print("rdx / rcx magnitude:")
    for (a, b), v in collections.Counter((bucket(h[4]), bucket(h[5])) for h in hot).most_common(6):
        print("  %5.1f %%  rdx %s, rcx %s" % (100.0 * v / nh, a, b))

    libc_path = next((m[4] for m in maps if m[4].endswith("libc.so.6")), None)
    if libc_path:
        for off, v in collections.Counter(h[0] for h in hot).most_common(2):
            print("--- objdump around libc+0x%x:" % off)
            r = subprocess.run(["objdump", "-d", "--no-show-raw-insn",
                                "--start-address=0x%x" % (off - 0x30),
                                "--stop-address=0x%x" % (off + 0x10), libc_path],
                               capture_output=True, text=True)
            print("\n".join(r.stdout.splitlines()[-14:]))
