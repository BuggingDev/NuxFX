#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NuxFX contributors
# After Effects 26 draws its panels with Adobe's Drawbot library, which records Direct2D drawing into command lists.
# Wine's d2d1.dll (up to and including Wine 11.20) answers ID2D1DeviceContext::EndDraw() on a device context whose
# target is a command list with E_NOTIMPL ("Unimplemented for command list target."), and Drawbot shows the box
# "After Effects warning: Direct2D Drawbot error. HRESULT: -2147467263".
# The fix in source form is patches-wine/0001-d2d1-end-drawing-to-a-command-list.patch (EndDraw() returns the
# error that the recording collected, S_OK when there is none, like it does for the other targets). This script
# makes the same change in the d2d1.dll of the Wine runner that install.sh unpacks, which is a pinned build: the
# 7 bytes of "jump to the FIXME, return E_NOTIMPL" in that function become "return S_OK". It changes the file only
# when its SHA-256 is the one of the pinned runner, and says so when it is another file.
#
#   scripts/patch_wine_d2d1.sh [--check] [d2d1.dll]    default: the d2d1.dll of the runner in WINE_BIN_DIR
# --check only says whether the fix is in (exit 0), or is missing from the pinned build (exit 4).
# Exit status: 0 patched or already patched, 3 not a d2d1.dll this script knows (nothing changed), 4 (--check) not
# patched yet, 1 error.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"
CHECK=0; [ "${1:-}" = --check ] && { CHECK=1; shift; }
DLL=${1:-$WINE_BIN_DIR/../lib/wine/x86_64-windows/d2d1.dll}
[ -f "$DLL" ] || { echo "no d2d1.dll at $DLL" >&2; exit 1; }
command -v python3 > /dev/null || { echo "python3 is needed" >&2; exit 1; }
python3 -I - "$DLL" "$CHECK" << 'PY'
import hashlib, os, re, sys

# d2d1.dll of wine-11.17-staging-tkg-amd64-wow64 (Kron4ek's build), before and after
ORIGINAL = '940c650b040cb05c542bb830eec0de057d131127463ca45448d5eee35cad5006'
PATCHED = '378062f4448ea5002ef2b885b1a48ed7b38c62786e200a9a17480224c87f53e9'

path = sys.argv[1]
check = sys.argv[2] == '1'
data = open(path, 'rb').read()
sha = hashlib.sha256(data).hexdigest()
if sha == PATCHED:
    print('d2d1.dll: EndDraw for command lists is already fixed')
    sys.exit(0)
if sha != ORIGINAL:
    print('d2d1.dll: not the file of the pinned Wine runner (SHA-256 %s); left alone' % sha[:12])
    sys.exit(3)
if check:
    print('d2d1.dll: the E_NOTIMPL return for command lists is still in (the pinned build, not patched)')
    sys.exit(4)
# test byte [rip+x], 1 ; jne +7 ; mov eax, E_NOTIMPL ; jmp back : the FIXME channel test and the return of E_NOTIMPL
pat = re.compile(rb'\xf6\x05....\x01\x75\x07\xb8\x01\x40\x00\x80\xeb.\x4c\x8d\x0d', re.S)
hits = list(pat.finditer(data))
if len(hits) != 1:
    print('d2d1.dll: the E_NOTIMPL return was found %d times, expected once; left alone' % len(hits))
    sys.exit(3)
at = hits[0].start() + 7
new = bytearray(data)
new[at:at + 7] = b'\x90\x90\x31\xc0\x90\x90\x90'   # nop nop ; xor eax,eax ; nop nop nop  (no FIXME, return S_OK)
tmp = path + '.nuxfx-tmp'
with open(tmp, 'wb') as f:
    f.write(new)
os.replace(tmp, path)
print('d2d1.dll: EndDraw for command lists now returns S_OK (patched at file offset %#x, new SHA-256 %s)' % (at, hashlib.sha256(new).hexdigest()))
PY
