#!/usr/bin/env python3
"""gen_override.py - generate a Qualcomm `edidoverride.xml` that injects
extra display modes into a monitor whose timings live in a DisplayID block
the driver cannot parse.

BACKGROUND
----------
Some 4K high-refresh monitors describe their high-refresh modes only in a
DisplayID 2.0 *Type X* (tag 0x2A, formula-based) block.  The qcdxkm8380
parser handles tags
    0x00 0x01 0x02 0x03 0x0F 0x12 0x20 0x21 0x22 0x25 0x26 0x28 0x29 0x2B 0x81
but NOT 0x2A, so those modes never reach the mode table.

This tool rewrites the requested modes as *Type VII* (tag 0x22, 20-byte
explicit timing records), which the driver does parse, and wraps the result
in the XML form the driver reads from C:\\Windows\\edidoverride.xml.

TIMING MATH
-----------
Timings are derived with the VESA CVT-RBv2 reduced-blanking formula, matching
`drm_mode_displayid_rb2()`:

    HBLANK = 80, HSYNC = 32, HFP = 8, VSYNC = 8, VBP = 6
    vfp is iterated:  vfp = 460 * hfreq / 1e6 + 1   (then -= vsync+vbp)
    pclk  = round((hactive + hblank) * vrefresh * vtotal / 1000)   [kHz]

Using `vactive + vblank` directly instead of the iterated `vtotal` produces a
timing the monitor accepts but reports one frame rate lower (119 instead of
120 on a 4K120 mode), so the iteration matters.

USAGE
-----
    python gen_override.py --base edid.bin 3840x2160@100 3840x2160@120
    python gen_override.py --base edid.bin --out edidoverride.xml 3840x2160@120
    python gen_override.py --list-cvt 3840x2160@120      # print timing only

The base EDID can be dumped from the registry with:
    .\\dump_edid.ps1 -Instance 'HEC107E\\3&9781174&8&UID1'
"""
import argparse
import sys

DISPLAYID_EXT_TAG = 0x70
TYPE7_TAG = 0x22

# CVT-RBv2 fixed parameters
HBLANK, HSYNC, HFP = 80, 32, 8
VSYNC, VBP = 8, 6


def cvt_rbv2(hactive, vactive, vrefresh):
    """Return the CVT-RBv2 timing for hactive x vactive @ vrefresh."""
    vfp = 1
    vtotal = vactive + VSYNC + VBP + vfp
    for _ in range(4):
        hfreq = vrefresh * vtotal
        vfp = (460 * hfreq) // 1_000_000 + 1
        if vfp < VSYNC + VBP + 1:
            vfp = 1
        else:
            vfp -= VSYNC + VBP
        new_total = vactive + vfp + VSYNC + VBP
        if new_total == vtotal:
            break
        vtotal = new_total

    hfreq = vrefresh * vtotal
    pclk = round((hactive + HBLANK) * hfreq / 1000)      # kHz
    return {
        'hactive': hactive, 'hblank': HBLANK,
        'hsync_offset': HFP, 'hsync_width': HSYNC,
        'vactive': vactive,
        'vtotal': vtotal, 'vblank': vtotal - vactive,
        'vsync_offset': vfp, 'vsync_width': VSYNC,
        'pclk': pclk,
        'hz': pclk * 1000 / ((hactive + HBLANK) * vtotal),
    }


def type7_record(t):
    """Encode one 20-byte DisplayID Type VII timing record.

    Every field is stored as (value - 1).
    """
    r = bytearray(20)
    r[0:3] = t['pclk'].to_bytes(3, 'little')
    r[3] = 0x00                                    # flags
    r[4:6] = (t['hactive'] - 1).to_bytes(2, 'little')
    r[6:8] = (t['hblank'] - 1).to_bytes(2, 'little')
    r[8:10] = (t['hsync_offset'] - 1).to_bytes(2, 'little')
    r[10:12] = (t['hsync_width'] - 1).to_bytes(2, 'little')
    r[12:14] = (t['vactive'] - 1).to_bytes(2, 'little')
    r[14:16] = (t['vblank'] - 1).to_bytes(2, 'little')
    r[16:18] = (t['vsync_offset'] - 1).to_bytes(2, 'little')
    r[18:20] = (t['vsync_width'] - 1).to_bytes(2, 'little')
    return bytes(r)


def displayid_ext(records):
    """Build a DisplayID 2.0 extension holding one Type VII block."""
    payload = b''.join(records)
    if len(payload) > 119:
        raise ValueError('too many timings: a DisplayID extension holds at most 5 records')
    ext = bytearray(128)
    ext[0:5] = bytes([DISPLAYID_EXT_TAG, 0x20, 0x79, 0x05, 0x00])
    ext[5:8] = bytes([TYPE7_TAG, 0x00, len(payload)])
    ext[8:8 + len(payload)] = payload
    ext[127] = (-sum(ext[:127])) & 0xFF
    return bytes(ext)


def build(base, records):
    """Return base block + non-DisplayID extensions + our DisplayID extension."""
    if len(base) < 128 or base[:8] != b'\x00\xff\xff\xff\xff\xff\xff\x00':
        raise ValueError('not an EDID: bad header')

    out = bytearray(base[:128])
    ext_count = 0
    for i in range(base[126]):
        off = 128 * (i + 1)
        ext = base[off:off + 128]
        if len(ext) < 128:
            break
        if ext[0] == DISPLAYID_EXT_TAG:
            continue                     # drop the old DisplayID block
        out += ext
        ext_count += 1

    out += displayid_ext(records)
    ext_count += 1
    out[126] = ext_count
    out[127] = (-sum(out[:127])) & 0xFF
    return bytes(out)


def to_xml(edid):
    """Render the driver's edidoverride.xml: BLOCK<n>><hex>, 128 bytes per line."""
    lines = []
    for i in range(0, len(edid), 128):
        lines.append(f'BLOCK{i // 128}>' + edid[i:i + 128].hex())
    return '\n'.join(lines) + '\n'


def parse_modes(specs):
    records, timings = [], []
    for spec in specs:
        try:
            res, hz = spec.lower().split('@')
            w, h = res.split('x')
            w, h, hz = int(w), int(h), int(hz)
        except ValueError:
            raise SystemExit(f'bad mode spec: {spec!r} (expected WxH@Hz)')
        t = cvt_rbv2(w, h, hz)
        timings.append((spec, t))
        records.append(type7_record(t))
    return records, timings


def main():
    ap = argparse.ArgumentParser(
        description='Generate edidoverride.xml with DisplayID Type VII timings.',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('modes', nargs='*', help='modes as WxH@Hz')
    ap.add_argument('--base', help='base EDID .bin to derive the override from')
    ap.add_argument('--out', default='edidoverride.xml', help='output XML path')
    ap.add_argument('--bin', help='also write the raw .bin here')
    ap.add_argument('--list-cvt', action='store_true',
                    help='only print the CVT-RBv2 timing for each mode')
    args = ap.parse_args()

    if not args.modes:
        ap.error('at least one mode is required')

    if args.list_cvt:
        for spec in args.modes:
            records, timings = parse_modes([spec])
            spec, t = timings[0]
            htotal = t['hactive'] + t['hblank']
            print(f'{spec}')
            print(f'   htotal={htotal} vtotal={t["vtotal"]} '
                  f'(vblank={t["vblank"]} vfp={t["vsync_offset"]})')
            print(f'   pclk={t["pclk"]} kHz -> {t["hz"]:.5f} Hz')
        return 0

    if not args.base:
        ap.error('--base is required unless --list-cvt is used')

    base = open(args.base, 'rb').read()
    records, timings = parse_modes(args.modes)

    print(f'base EDID: {args.base} ({len(base)} bytes, {base[126]} extensions)')
    for spec, t in timings:
        bw = t['pclk'] * 24 / 1e6
        print(f'   {spec}: pclk={t["pclk"]} kHz  vtotal={t["vtotal"]}  '
              f'-> {t["hz"]:.5f} Hz   ({bw:.2f} Gbps at 24bpp)')

    try:
        edid = build(base, records)
    except ValueError as ex:
        raise SystemExit(f'error: {ex}')

    xml = to_xml(edid)
    open(args.out, 'w', newline='\n').write(xml)
    print(f'wrote {args.out} ({len(edid)} bytes, {edid[126]} extensions)')

    if args.bin:
        open(args.bin, 'wb').write(edid)
        print(f'wrote {args.bin}')

    checks = [sum(edid[i * 128:(i + 1) * 128]) & 0xFF for i in range(len(edid) // 128)]
    print(f'block checksums: {checks}  (all must be 0)')
    return 0 if all(c == 0 for c in checks) else 1


if __name__ == '__main__':
    raise SystemExit(main())
