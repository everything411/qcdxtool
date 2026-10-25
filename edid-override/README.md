# edid-override

Generate and inject a Qualcomm `edidoverride.xml` so that a display can offer
modes the driver would otherwise drop.

Built for one specific problem: a 4K monitor whose 4K100 / 4K120 timings exist
only in a **DisplayID 2.0 Type X** (`0x2A`) block, which `qcdxkm8380` does not
parse. The same timings re-expressed as **Type VII** (`0x22`) records are
accepted, because the driver does handle that tag. Background:
[`../qcdxtool/docs/DISPLAY_MODES.md`](../qcdxtool/docs/DISPLAY_MODES.md).

## Requirements

* `qcdx_edid.exe` built from `../qcdxtool` (see its README).
* Administrator, but **only** to write `C:\Windows\edidoverride.xml`. The
  escape calls themselves need no elevation.
* The target display must be stopped (unplugged or powered off) while the
  override is injected.

## Generate

```powershell
python gen_override.py --base edid_stock.bin --out edidoverride.xml \
       --bin override.bin 3840x2160@100 3840x2160@120
```

* `--base` is the stock EDID of the monitor. Dump it from the registry with
  `tools/dump_edid.ps1` (see below) or read it from
  `HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\<id>\Device Parameters\EDID`.
* Modes are `WIDTHxHEIGHT@REFRESH`.
* Existing DisplayID extensions are replaced; CEA and other extensions are
  kept; the base block checksum and extension count are recomputed.
* `--list-cvt 3840x2160@120` prints the computed timing without writing files.

At most 5 timings fit in one DisplayID extension (119 usable bytes).

## Apply

```powershell
.\apply.ps1 -Index 4 -File edidoverride.xml
```

The script walks the mandatory order:

```
install XML  ->  stop the display  ->  clear + load  ->  start the display  ->  verify
```

It refuses to inject while the target slot is active. `-Auto` skips the two
Enter prompts (it waits up to 60 s for the display to disappear instead).

Revert:

```powershell
.\apply.ps1 -Revert -Index 4
```

## Lifecycle - read this before filing a bug

The override lives in **RAM only**:

* read by the driver when the display starts;
* freed when the display stops;
* **gone after reboot**.

So it has to be re-applied after every hotplug and every boot. That is why
there is no daemon: run `apply.ps1` when you need the extra modes.

## Dumping the stock EDID

```powershell
$id = 'HEC107E\3&9781174&8&UID1'      # find yours under DISPLAY\*
$b  = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\$id\Device Parameters").EDID
[IO.File]::WriteAllBytes("$PWD\edid_stock.bin", $b)
```

Verify that the driver is serving the override by re-reading the same value:
its length and bytes should match the generated `.bin`.

## Caveats

* Two constraints are enforced by the driver, not by this tool: the refresh
  rate must be <= 120 Hz, and above ~864 MHz pixel clock the mode is delivered
  at 24bpp instead of 30bpp (see `DISPLAY_MODES.md` section 4).
* 4K120 over a 4-lane HBR3 link without DSC occupies 99.6% of the bandwidth.
  It works, but 4K100 (82%) is the safer choice if you see dropouts.
* The Mode List in the driver dump is authoritative. Windows' own list is
  derived from it, so both change together.
* If the monitor OSD shows 119 Hz instead of 120, the `vtotal` was computed
  without the CVT-RBv2 `vfp` iteration - see `DISPLAY_MODES.md` section 5.

## Samples

| file | content |
|---|---|
| `samples/edid_27GX_4k100_120.bin` | ready-made override EDID (base + CEA + Type VII 4K100/4K120) |
| `samples/edidoverride_M.xml` | the same EDID in the driver's XML form |
