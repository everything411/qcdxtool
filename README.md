# qcdx-rev

Reverse-engineering notes and tools for the **Qualcomm Adreno display
miniport `qcdxkm8380.sys`** on Snapdragon X Elite, plus a practical use of it:
adding 4K100 / 4K120 modes to an external DisplayPort monitor that the driver
refuses to expose.

Two parts:

| part | what it is |
|---|---|
| [`qcdxtool/`](qcdxtool/) | userspace tool for the driver's private `DxgkDdiEscape` commands, with the full interface specification |
| [`edid-override/`](edid-override/) | generator and injector for an `edidoverride.xml` that adds display modes |

## The short version

The driver's private escape interface has three command words
(`0x20000002`, `0x20000100`, `0x20000101`). Between them they can enumerate
displays, read DPCD over AUX, change the DP link configuration, set panel
colour, dump the complete internal display state to a file, and install an
arbitrary EDID for a display child.

The EDID override is what solves the practical problem: a monitor whose 4K100
and 4K120 timings live only in a DisplayID **Type X** (`0x2A`) block gets no
such modes, because the driver's DisplayID parser does not handle tag `0x2A`.
Re-encoding the same timings as **Type VII** (`0x22`) records - which it does
handle - and injecting them through the override makes both modes appear and
work at their exact refresh rates.

No driver patching, no test signing, no secure-boot changes.

## Quick start

```powershell
# build the tool
cd qcdxtool\src
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" `
    /target:exe /out:qcdx_edid.exe /platform:anycpu qcdx_edid.cs

# verify it works on this machine (read-only)
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tools\selftest.ps1

# add 4K100 / 4K120 to the monitor on slot 4
cd ..\..\edid-override
.\apply.ps1 -Index 4 -File samples\edidoverride_M.xml
```

## Documentation

| document | content |
|---|---|
| [`qcdxtool/docs/ESCAPE_SPEC.md`](qcdxtool/docs/ESCAPE_SPEC.md) | the escape interface: structures, dispatch, every command, the driver bugs |
| [`qcdxtool/docs/DISPLAY_MODES.md`](qcdxtool/docs/DISPLAY_MODES.md) | why 4K100/120 are missing, and how the Type VII override fixes it |

## Scope and caution

* Everything here is reverse-engineered from a specific build of
  `qcdxkm8380.sys`. Addresses are build specific - `qcdxtool/tools/verify_build.py`
  checks whether your copy matches, and `audit.py` re-derives the command
  tables from the binary.
* Some `set:` keys write their configuration to disk and **survive a reboot**.
  The tool gates them behind `--persist-ok`, and `restore_color.ps1` resets
  them, but read `qcdxtool/README.md` before writing anything.
* `preemphasis`, `voltageswing`, `testpattern` and `AuxWrite` touch transmitter
  equalisation, panel test patterns and the sink's DPCD. They are documented
  but were never executed during this work.
* Not affiliated with Qualcomm or Microsoft.
