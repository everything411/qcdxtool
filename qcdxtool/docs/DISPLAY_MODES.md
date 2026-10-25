# Why a 4K high-refresh monitor offers no 4K100/4K120 mode

Tested with a 3840x2160 monitor that supports 4K100 and 4K120, connected over
USB-C DisplayPort alt mode (4 lanes, no DSC), driven by `qcdxkm8380`.

## 1. Symptom

Windows offers 17 modes for the display - 4K50/60, 1440p120, 1080p100/120 and
the usual smaller ones - but not 4K100 or 4K120, even though the monitor's
EDID advertises them and the link has enough bandwidth.

## 2. Root cause

The monitor describes 4K100/4K120 **only** in a DisplayID 2.0 **Type X**
(tag `0x2A`, formula-based timing) block. The driver's DisplayID parser
(`FUN_1401A9BA0`) dispatches on the block tag and supports

```
0x00 0x01 0x02 0x03 0x0F 0x12 0x20 0x21 0x22 0x25 0x26 0x28 0x29 0x2B 0x81
```

`0x2A` is not in the list and falls through to the default case, so the timings
are dropped before they reach the per-display timing table
(`FUN_140159750` writes it, `FUN_140159C50` validates it).

Every other carrier **is** consumed:

| EDID carrier | becomes a mode |
|---|---|
| base detailed timing descriptor (DTD) | yes |
| CEA-861 VIC (<= 116) | yes |
| CEA-861 VIC 117 / 118 | no (Windows' VIC table does not map them) |
| DisplayID Type VII (`0x22`) | **yes** |
| DisplayID Type X (`0x2A`) | no |

So the fix is not a driver patch: describe the same timings as **Type VII**
records, which the driver does parse, and inject them with an EDID override.

## 3. Reproducing it

`../edid-override/gen_override.py` builds the override from the stock EDID:

```
python gen_override.py --base edid_stock.bin --out edidoverride.xml \
       --bin override.bin 3840x2160@100 3840x2160@120
```

Then `../edid-override/apply.ps1` installs it and injects it into the driver.
After a replug the driver's own mode list contains the new modes:

```
Display-Mode#4-17: 3840x2160 @ 100Hz, PClk:887880000Hz,  Depth: 24bpp
Display-Mode#4-18: 3840x2160 @ 120Hz, PClk:1075805000Hz, Depth: 24bpp
```

Selectable in Settings > System > Display > Advanced display.

## 4. Two constraints the driver imposes

Discovered by injecting ladders of otherwise identical timings:

| constraint | evidence |
|---|---|
| **refresh rate <= 120 Hz** | 3200x1800@120 accepted; @122, @124, @126, @128, @130 all rejected |
| **pclk above ~864 MHz switches the mode to 24bpp**, it is not rejected | 4K@83-87 Hz (790-828 MHz) reported `30bpp`; 4K@91/92 Hz (866/875 MHz) reported `24bpp` and were still offered |

864 MHz is `25.92 Gbps / 30bpp`, i.e. the pixel clock that still fits the link
at 10 bits per channel. Above it the driver keeps the mode and drops to
24bpp instead of refusing it. That downshift is why 4K120 fits at all:
`1,075,805 kHz x 24 = 25.82 Gbps` against a 25.92 Gbps HBR3 4-lane link
(99.6%). 4K100 sits at 82%.

## 5. Timing math: use CVT-RBv2, and iterate `vfp`

Type VII records carry explicit timings, so the CVT-RBv2 reduced-blanking
formula must be evaluated yourself. Matching
`drm_mode_displayid_rb2()`:

```
HBLANK = 80, HSYNC = 32, HFP = 8, VSYNC = 8, VBP = 6

vfp = 1
vtotal = vactive + vsync + vbp + vfp
repeat up to 4 times:
    hfreq = vrefresh * vtotal
    vfp   = (460 * hfreq) / 1000000 + 1
    if vfp < vsync + vbp + 1: vfp = 1
    else:                     vfp -= vsync + vbp
    if vtotal == vactive + vfp + vsync + vbp: break
    vtotal = vactive + vfp + vsync + vbp

pclk = round((hactive + hblank) * vrefresh * vtotal / 1000)   [kHz]
```

For 4K120 the iteration is:

```
iter0: vtotal=2175  hfreq=261000  vfp=107 -> 2281
iter1: vtotal=2281  hfreq=273720  vfp=112 -> 2286
iter2: vtotal=2286  hfreq=274320  vfp=113 -> 2287
iter3: vtotal=2287            vfp=113 -> 2287   converged
pclk = round(3920 * 274440 / 1000) = 1,075,805 kHz
```

**Do not use `vactive + vblank` as `vtotal`.** Doing so gives `vtotal = 2222`
and `pclk = 1,045,229 kHz`. The math still evaluates to 120.000 Hz, but the
monitor does not recognise the timing and reports **119 Hz** on its OSD. With
the iterated `vtotal = 2287` it reports 120.

## 6. Type VII record encoding

20 bytes, **every field is stored as `value - 1`**:

| offset | field |
|---|---|
| 0-2 | pixel clock in kHz, 24-bit little endian |
| 3 | flags (0) |
| 4-5 | hactive - 1 |
| 6-7 | hblank - 1 |
| 8-9 | hsync start (front porch) - 1 |
| 10-11 | hsync width - 1 |
| 12-13 | vactive - 1 |
| 14-15 | vblank - 1 |
| 16-17 | vsync start (front porch) - 1 |
| 18-19 | vsync width - 1 |

Forgetting the `-1` shifts the timing by one pixel/line and the record is
silently discarded - the mode simply never appears.

## 7. Override lifecycle

The override is **RAM only**:

* it is read when the display starts;
* it is freed when the display stops (`FUN_140047158`);
* it does not survive a reboot.

Therefore the injection sequence is always

```
install XML  ->  stop the display  ->  clear + load  ->  start the display
```

and it must be repeated after every hotplug and every boot.
`clear` must precede `load`; a same-boot `load` alone may not replace an
existing slot.
