"""audit.py - re-verify every address/table/claim in docs/ESCAPE_SPEC.md
against the driver binary itself.

No Ghidra export needed: parses the PE, decodes instructions, and re-derives
the command tables, key strings and the persistence classification.

Usage:
    python audit.py [path\\to\\qcdxkm8380.sys ...]
Exit code 0 = all checks passed.
"""
import glob
import struct
import sys

IMG = 0x140000000

CANDIDATES = glob.glob(
    r'C:\Windows\System32\DriverStore\FileRepository\qcdx8380.inf_arm64_*\qcdxkm8380.sys')
CANDIDATES += sys.argv[1:]

# ---- expected values, as documented -------------------------------------
EXPECT_GET = [
    ("displays", 0x140115D30),
    ("displaycaps", 0x140115E40),
    ("AuxRead", 0x1401160B0),
    ("captureread", 0x140116660),
]
# (name, handler, size) - size bounds the function body so the BL scan is exact
EXPECT_SET = [
    ("sharpness",    0x1401131B0, 632),  ("warmness",    0x140113430, 1168),
    ("hue",          0x140113B50, 252),  ("saturation",  0x140113C50, 252),
    ("intensity",    0x140113D50, 252),  ("contrast",    0x140113E50, 252),
    ("linkrate",     0x140114D30, 332),  ("lanecount",   0x140114E90, 332),
    ("preemphasis",  0x140114FF0, 332),  ("voltageswing",0x140115150, 336),
    ("testpattern",  0x1401152B0, 336),  ("pcc",         0x140113F50, 572),
    ("igc",          0x140114190, 1088), ("3dlut",       0x1401145E0, 1864),
    ("AuxWrite",     0x1401128E0, 740),
]
EXPECT_CAPS = ["sharpness", "warmness", "hue", "saturation", "intensity",
               "contrast", "plugable", "pcc", "igc", "3dlut", "screencapture"]
EXPECT_STRINGS = {
    0x1401E39D8: "displayId",
    0x1401E39E8: "status",
    0x1401E3A00: "mode",
    0x1401E3A08: "numBytes",
    0x1401E3B98: "AuxRead",
}
PERSIST_FN = 0x140138458
EXPECT_PERSIST = {"sharpness", "warmness", "hue", "saturation",
                  "intensity", "contrast", "pcc", "3dlut"}


class Img:
    def __init__(self, path):
        self.path = path
        self.b = open(path, 'rb').read()
        e = struct.unpack('<I', self.b[0x3C:0x40])[0]
        nsec = struct.unpack('<H', self.b[e+6:e+8])[0]
        optsz = struct.unpack('<H', self.b[e+20:e+22])[0]
        opt = e + 24
        self.secs = []
        for s in range(nsec):
            o = opt + optsz + 40 * s
            vsz, va, rsz, rp = struct.unpack('<IIII', self.b[o+8:o+24])
            self.secs.append((va, vsz, rp, rsz))

    def off(self, rva):
        for va, vsz, rp, rsz in self.secs:
            if va <= rva < va + max(vsz, rsz):
                return rp + (rva - va)
        return None

    def word(self, rva):
        o = self.off(rva)
        return struct.unpack('<I', self.b[o:o+4])[0]

    def cstr(self, va, n=48):
        o = self.off(va - IMG)
        if o is None:
            return '?'
        return self.b[o:o+n].split(b'\0')[0].decode(errors='replace')


def read_table(img, va, count):
    o = img.off(va - IMG)
    out = []
    for i in range(count):
        q = struct.unpack('<QQQ', img.b[o+i*24:o+i*24+24])
        out.append((img.cstr(q[0]), q[1]))
    return out


def scan_bl(img, start, size, target):
    """Return True if a BL to `target` exists in [start, start+size)."""
    for i in range(0, size, 4):
        rva = start - IMG + i
        o = img.off(rva)
        if o is None:
            continue
        w = struct.unpack('<I', img.b[o:o+4])[0]
        if (w >> 26) != 0x25:          # BL opcode
            continue
        imm = w & 0x3FFFFFF
        if imm & (1 << 25):
            imm -= (1 << 26)
        if rva + IMG + (imm << 2) == target:
            return True
    return False


def run(path):
    img = Img(path)
    fails = []

    def check(name, ok, detail=''):
        print(f'  [{"PASS" if ok else "FAIL"}] {name}' + (f'   {detail}' if detail else ''))
        if not ok:
            fails.append(name)

    # Fingerprint first: skip builds this document was not written against.
    w = img.word(0x46E4A0)
    if w != 0xD503237F:
        print(f'== skip {path}')
        print(f'   fingerprint mismatch (0x14046E4A0 = {w:#010x}, want 0xd503237f)')
        return 1

    print(f'== audit {path}')
    print(f'   size={len(img.b)}')
    check('DxgkDdiEscape prologue', True, '0x14046E4A0 = pacibsp')

    got = read_table(img, 0x140303E50, len(EXPECT_GET))
    check('get table', got == EXPECT_GET,
          '; '.join(f'{n}->{h:#x}' for n, h in got))

    got = read_table(img, 0x140303ED0, len(EXPECT_SET))
    check('set table', [g[0] for g in got] == [e[0] for e in EXPECT_SET],
          f'{len(got)} entries, first={got[0][0]}, last={got[-1][0]}')

    got = read_table(img, 0x14030CCB0, len(EXPECT_CAPS))
    check('displaycaps sub-keys', [n for n, _ in got] == EXPECT_CAPS,
          ', '.join(n for n, _ in got))

    for va, exp in EXPECT_STRINGS.items():
        s = img.cstr(va, len(exp) + 4)
        check(f'string @{va:#x}', s == exp, f'{s!r}')

    for name, handler, size in EXPECT_SET:
        has = scan_bl(img, handler, size, PERSIST_FN)
        want = name in EXPECT_PERSIST
        check(f'persistence {name:<12}', has == want,
              'calls FUN_140138458' if has else 'does not call')

    print()
    if fails:
        print(f'{len(fails)} check(s) failed')
        for f in fails:
            print('  - ' + f)
        return 1
    print('all checks passed')
    return 0


def main():
    if not CANDIDATES:
        print('qcdxkm8380.sys not found')
        return 2
    for p in CANDIDATES:
        if not p:
            continue
        try:
            if run(p) == 0:
                return 0
        except Exception as ex:                                # noqa: BLE001
            print(f'  skip {p}: {ex}')
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
