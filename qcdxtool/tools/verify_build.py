"""verify_build.py - check that a qcdxkm8380.sys build matches the addresses
used in docs/ESCAPE_SPEC.md.

Two fingerprints are verified:
  1. RVA 0x46E4A0 must start with `pacibsp` (0xD503237F) - DxgkDdiEscape.
  2. RVA 0x116234 must be an adrp+add pair resolving to the string "mode".

Usage:
    python verify_build.py [extra\\path\\to\\qcdxkm8380.sys ...]
Exit code 0 = at least one candidate matches.
"""
import glob
import os
import struct
import sys

IMG = 0x140000000
CANDIDATES = glob.glob(
    r'C:\Windows\System32\DriverStore\FileRepository\qcdx8380.inf_arm64_*\qcdxkm8380.sys')
CANDIDATES += sys.argv[1:]


def parse(path):
    b = open(path, 'rb').read()
    e = struct.unpack('<I', b[0x3C:0x40])[0]
    nsec = struct.unpack('<H', b[e+6:e+8])[0]
    optsz = struct.unpack('<H', b[e+20:e+22])[0]
    opt = e + 24
    secs = []
    for s in range(nsec):
        o = opt + optsz + 40 * s
        vsz, va, rsz, rp = struct.unpack('<IIII', b[o+8:o+24])
        secs.append((va, vsz, rp, rsz))
    return b, secs


def r2o(secs, rva):
    for va, vsz, rp, rsz in secs:
        if va <= rva < va + max(vsz, rsz):
            return rp + (rva - va)
    return None


def check(path):
    b, secs = parse(path)
    o = r2o(secs, 0x46E4A0)
    if o is None:
        return False, 'no .text mapping'
    ok_escape = b[o:o+4] == b'\x7f\x23\x03\xd5'

    ok_mode = False
    detail = ''
    try:
        o1 = r2o(secs, 0x116234)
        w = struct.unpack('<I', b[o1:o1+4])[0]
        immlo = (w >> 29) & 3
        immhi = (w >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        if imm & (1 << 20):
            imm -= (1 << 21)
        page = (IMG + 0x116234) & ~0xFFF
        tgt = page + (imm << 12)
        w2 = struct.unpack('<I', b[o1+4:o1+8])[0]
        addr = tgt + ((w2 >> 10) & 0xFFF)
        o2 = r2o(secs, addr - IMG)
        s = b[o2:o2+16].split(b'\0')[0]
        detail = f'adrp+add -> {addr:#x} = {s!r}'
        ok_mode = s == b'mode'
    except Exception as ex:                                    # noqa: BLE001
        detail = f'decode failed: {ex}'

    return (ok_escape and ok_mode), detail


def main():
    if not CANDIDATES:
        print('qcdxkm8380.sys not found')
        return 1
    good = []
    for p in CANDIDATES:
        if not os.path.exists(p):
            continue
        ok, detail = check(p)
        print(f'[{"MATCH  " if ok else "mismatch"}] {p}')
        print(f'          size={os.path.getsize(p)}  {detail}')
        if ok:
            good.append(p)
    print()
    if good:
        print(f'{len(good)} build(s) match the documented addresses:')
        for p in good:
            print('  ' + p)
        return 0
    print('No candidate matches. Re-analyse with a matching build, or update the docs.')
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
