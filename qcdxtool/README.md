# qcdxtool

Userspace tool and reference notes for the **Qualcomm Adreno display miniport
`qcdxkm8380.sys`** (Snapdragon X Elite, `qcdx8380.inf`), reached through its
private `DxgkDdiEscape` commands.

The interface is undocumented and unexported: everything here was recovered by
disassembling the driver and then calling it. See
[`docs/ESCAPE_SPEC.md`](docs/ESCAPE_SPEC.md) for the full interface and
[`docs/DISPLAY_MODES.md`](docs/DISPLAY_MODES.md) for the display-mode
findings.

## Capabilities

| Command | What it does |
|---|---|
| `get:` text interface | enumerate displays, query per-display capabilities, read DPCD over AUX |
| `set:` text interface | link rate / lane count, panel color, LUT upload |
| diagnostics dump | dump the driver's complete display state to a file |
| EDID override | install an arbitrary EDID for one display child |
| clock query | map a frequency to the nearest display clock tier |

## Build

The tool is a single C# file with no dependencies. Any C# compiler works; the
one that ships with .NET Framework is enough (this is what has been tested):

```powershell
csc /target:exe /out:qcdx_edid.exe /platform:anycpu qcdx_edid.cs
```

Windows 11 has no `csc` on `PATH`; use the framework copy:

```powershell
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" `
    /target:exe /out:qcdx_edid.exe /platform:anycpu qcdx_edid.cs
```

Put the result in `src/` (next to the source) or `bin/`; the PowerShell helpers
look in both.

## Usage

```
qcdx_edid.exe --get "<selector>"          C3 0x20000101 text interface
qcdx_edid.exe --dump <name>               C2 0x105, writes C:\data\test\<name>
qcdx_edid.exe --c2 <cmd> <idx> <arg>      C2 0x20000100 raw command
qcdx_edid.exe --clock <idx> <freq>        C1 0x20000002 clock lookup
qcdx_edid.exe --index <n> [--clear]       C2 0x106 sub-op 2, EDID override
```

Modifiers: `--display <name>` (default: probe `\\.\DISPLAY1..16`), `--dry`,
`--allow-internal`, `--persist-ok`.

### Examples

```powershell
# what is attached
.\qcdx_edid.exe --get "get:displayId"
.\qcdx_edid.exe --get "get:displayId:4,displaycaps:plugable;screencapture"

# full diagnostics dump -> C:\data\test\diag.txt
New-Item -ItemType Directory C:\data\test -Force | Out-Null
.\qcdx_edid.exe --dump diag.txt

# DPCD 0x100 (link rate / lanes).  NOTE: mode must be 2, address in DECIMAL
.\qcdx_edid.exe --get "get:displayId:4,AuxRead:256,mode:2,numBytes:16"
```

## Write safety

The driver has two classes of setters and the tool enforces the distinction:

| gate | applies to | unlock |
|---|---|---|
| persistence | `sharpness warmness hue saturation intensity contrast pcc 3dlut` - their setters call `FUN_140138458`, which *attempts* to store the config through the miniport settings API | `--persist-ok` |
| non-plugable slot | a slot whose `displaycaps:plugable` is 0 (observed: `1`, `2`, `3`, `7`) - slot 1 is the internal eDP panel, the others look like unused slots | `--allow-internal` |

**The setter ignores the result of that store attempt**, so `status:0` proves the
value was applied, not that it was saved - but the store is real and survives a
reboot. It lives at

```
HKLM\SOFTWARE\QCOM\Drivers\DxKMD\Miniport\DISPLAY\Config
```

with 4-character value-name tags: `SHRP` (4 bytes, sharpness) and `HSIC`
(20 bytes: header, hue, saturation, intensity, contrast). A neutral
configuration is `SHRP = 00 00 00 00` and `HSIC = 01 00 00 00` + 16 zero bytes.

If you write one of these, write the neutral value back immediately:

| key | range | neutral |
|---|---|---|
| `hue` | -180 .. +180 | 0 |
| `contrast` | -100 .. +100 | 0 |
| `sharpness` | -100 .. +100 | 0 |

`tools/restore_color.ps1` does exactly that.

`displaycaps` returns **capability flags** (1/0), not current values - it
cannot be used to confirm that a write took effect.

Never write `preemphasis`, `voltageswing`, `testpattern` or `AuxWrite` unless
you know what you are doing: they change transmitter equalisation, panel test
patterns, or write directly to the sink's DPCD.

## Helper scripts

| script | purpose |
|---|---|
| `tools/selftest.ps1` | read-only end-to-end check (build, audit, displays, query, dump) |
| `tools/verify_build.py` | confirm the analysed build matches the documented RVAs |
| `tools/audit.py` | re-derive the command tables / strings / persistence flags from the binary |
| `tools/probe_dp.ps1` | read-only DP probe: slots, DPCD 0x100, dump summary |
| `tools/modes.ps1` | enumerate Windows modes (`-Current` for the active one) |
| `tools/restore_color.ps1` | reset persisting color keys to neutral |

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\selftest.ps1
python tools\verify_build.py
python tools\audit.py
```

## Samples

| file | content |
|---|---|
| `samples/edid_27GX_stock.bin` | stock EDID of the test monitor (512 bytes, DisplayID Type X) |
| `samples/edid_internal_panel.bin` | internal eDP panel EDID (2 base DTDs) |
| `samples/diagnostics_example.txt` | a `--dump` result: internal panel plus an external 4K monitor running 4K120 |

## Notes

* Addresses in the docs are build specific. `verify_build.py` tells you whether
  your copy matches. DriverStore can hold several copies of the driver; always
  resolve the one `HKLM\SYSTEM\CurrentControlSet\Services\QCDX` loads.
* The escape result is **not** the NTSTATUS. Each command writes its own status
  into the private data block; see the spec for the offsets.
* The `D3DKMT*` entry points are named `D3DKMT` + verb: `D3DKMTOpenAdapterFromGdiDisplayName`,
  `D3DKMTCreateDevice`, `D3DKMTEscape`, `D3DKMTDestroyDevice`, **`D3DKMTCloseAdapter`**.
  Note there is no `C` between `D3DKMT` and `CloseAdapter` - an early version of
  this tool spelled it `D3DKMTCCloseAdapter`, which does not exist, so every run
  completed its work and then died in cleanup with
  `EntryPointNotFoundException` (CLR20r3, exit code `0xE0434352`). All five names
  are present in `gdi32.dll` on ARM64 build 29695.1001.
* Adapter and device cleanup is best effort anyway: a missing export prints a
  `[warn]` instead of turning a successful command into a crash.
* `qcdx_edid --dump` creates `C:\data\test` for you; the driver only writes
  there and reports `status @+0xD8 = 4` if the directory is missing.






