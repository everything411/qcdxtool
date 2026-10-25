# qcdxkm8380 private `DxgkDdiEscape` interface

Reverse-engineered from `qcdxkm8380.sys` (Qualcomm Adreno display miniport,
Snapdragon X Elite / `qcdx8380.inf`, build `..._be52f1b0c83c4f02`).

Everything below was derived from disassembly and then confirmed by calling
the live driver. Unverified items are marked **[unverified]**.

The driver exports 193-slot `DRIVER_INITIALIZATION_DATA`; `DxgkDdiEscape` is
slot 34 (`FUN_14046E4A0`). It links `DxgkInitialize` statically, so the module
has no `dxgkrnl` imports - absence of such imports does not mean it is not a
display miniport.

---

## 1. Reaching the escape

Three user-mode calls, all exported by `gdi32.dll`:

```
D3DKMTOpenAdapterFromGdiDisplayName(&open)   -> hAdapter
D3DKMTCreateDevice(&create)                  -> hDevice
D3DKMTEscape(&escape)                        -> NTSTATUS
```

### 1.1 `D3DKMTOpenAdapterFromGdiDisplayName` argument

| off | type | field |
|---|---|---|
| 0x00 | `WCHAR[32]` | GDI device name, e.g. `\\.\DISPLAY1` |
| 0x40 | `UINT` | output `hAdapter` |

Buffer size 80 bytes.

### 1.2 `D3DKMTCreateDevice` argument - **pitfall**

| off | type | field |
|---|---|---|
| 0x00 | `D3DKMT_HANDLE` (8 bytes on ARM64) | input `hAdapter` |
| 0x08 | `UINT` | `Flags` |
| 0x0C | `UINT` | **output `hDevice`** |

`hDevice` is at **0x0C**, not 0x00. Writing it at 0x00 yields
`hDevice == hAdapter` and every later escape fails.
Buffer size 64 bytes (`0x40`); the driver only reads the first 0x10.

### 1.3 `D3DKMT_ESCAPE` - **pitfall**

| off | type | field |
|---|---|---|
| 0x00 | `UINT` | `hAdapter` (4 bytes!) |
| 0x04 | `UINT` | `hDevice` (4 bytes!) |
| 0x08 | `UINT` | `Type` |
| 0x0C | `UINT` | `Flags` |
| 0x10 | `VOID*` | `pPrivateDriverData` |
| 0x18 | `SIZE_T` | `PrivateDriverDataSize` |

Buffer size 0x20. The usual mistake is to write 8-byte handles at 0x00/0x08;
that leaves `hDevice` at +0x04 as zero and the call returns `0xC000000D`
(`STATUS_INVALID_PARAMETER`).

`Type` selects the escape class; the private commands below all use
`Type = 1` (`D3DKMT_ESCAPE_DRIVERPRIVATE`).

### 1.4 Private data block layout

The block passed via `pPrivateDriverData` is at least 0x9000 bytes for the
text interface and exactly `0x4854` for command word `0x20000100`.

| off | `0x20000100` (C2) | `0x20000101` (C3) |
|---|---|---|
| 0x88 | ASCII payload length | buffer capacity (checked against `size`) |
| 0x8C | command word `cmd` | text length in / **result length out** |
| 0x90 | command block start | text start |

`0x8C` is dual purpose: the command word for C2, the text length (and, after
the call, the reply length) for C3.

`cmd >> 28` is the namespace. `ns == 2` means a Qualcomm private command.
Dispatch requires `ctx->[0x3F50] != 0` (device created), `size >= 0x40` and
`(cmd & 0xF0000000) == 0x20000000`.

---

## 2. Command word `0x20000002` - clock-tier lookup (C1)

Preconditions: `size == 0xA0`, `*(u32*)(d+0x88) == 8`, `*(u32*)(d+0x94) == 8`.

Looks up the clock tier whose frequency is closest to the requested value and
returns it. Outputs live at `d+0x98` and `d+0x9C`.

Observed: the escape always succeeds, but both outputs are 0 when the target
display is off - the clock table is only populated for active targets.

---

## 3. Command word `0x20000100` - display configuration (C2)

Preconditions: `size == 0x4854`. The command word inside the block is
`cmd = *(u32*)(d + 0x8C)`; per-command parameters follow at `d + 0x90` onwards.

**The result is never in the NTSTATUS.** Each command writes its own status
into the block:

| command | status offset |
|---|---|
| `0x105` | `+0xD8` |
| `0x106` | `+0x1C` |
| `0x109` | `+0x4C` |
| `0x10C` | `+0x4C` |

### 3.1 Sub-operations of `0x106`

`sub = *(u32*)(d + 0x90)`.

| sub | action | status |
|---|---|---|
| 1 | display power/state transition via `FUN_14004E820(perDisplay, value)`; value at `d+0x9C` | `+0x1C` |
| 2 | **EDID override** - index at `d+0x94`, "clear" flag at `d+0x98` | `+0x1C` |
| 3 | allocate a LUT buffer sized by tier (`bpp x height x width`) then upload | `+0x1C` |
| 4 | needs capability bit 24 and display state 2; operates on a 1032-byte block | `+0x1C` |
| 5 | sets feature bits `0x1000 / 0x2000 / 0x8000` in `DAT_140385B90[idx]` and submits | `+0x1C` |

Sub-op 2 is the useful one: it makes the driver read
`C:\Windows\edidoverride.xml` and install it as the EDID of the given display
child. See `DISPLAY_MODES.md` and the `edid-override/` directory.

### 3.2 `0x105` - diagnostics dump

Writes a text dump to `C:\data\test\<name>`. `C:\data\test` must already
exist; the driver does not create it. Status lands at `+0xD8`; `0` means the
file was written (7-16 KB depending on how many displays are active).

The dump contains, per display: connection type, mode set index, resolution,
refresh rate, dynamic-refresh-rate list, clock/bandwidth votes, blend space,
layer list, DP configuration (lane count, link rate, DSC status, mode list),
statistics and brightness/LTM configuration.

### 3.3 `0x107` - feature switches

`sub = *(u32*)(d+0x90)`.

* `sub == 1` - for **every** display, clear bit 28 of `DAT_140388930[idx]`
  and set it again when `*(u32*)(d+0x98) != 0`.
* `sub == 2` - CABL (content-adaptive backlight) configuration; the
  `"DisableCABL"` string and opcode `0x36` appear in this path.

### 3.4 `0x109` - state query

`size > 0x17`, index at `d+0x90`. The block is zeroed and then filled; the
result is at `+0x4C`. Observed all-zero when the target display is off.

### 3.5 `0x10C` - two per-display parameters

Index at `d+0x90`, flags at `d+0x98`:

```c
if (flags & 1)      { DAT_1403857BC[idx] = *(u32*)(d + 0x9C); submit; }   /* sets 0x400 */
if ((flags >> 1) & 1) { DAT_1403857B0[idx] = *(u32*)(d + 0xA0); submit; } /* sets 0x800 */
```

Status at `+0x4C`. The meaning of the two parameters is not established.

---

## 4. Command word `0x20000101` - text get/set interface (C3)

Preconditions:

```c
if (size < 0x94)                       return STATUS_INVALID_PARAMETER;
if (size < *(u32*)(d + 0x88) + 0x90)   return STATUS_INVALID_PARAMETER;
```

`*(u32*)(d+0x88)` is the buffer **capacity**, the text starts at `d+0x90`,
its length is `*(u32*)(d+0x8C)`, and the driver writes the reply back into the
same buffer (length, then text).

### 4.1 Grammar

```
<text> ::= "get:" <selector> | "set:" <assignment-list>
<selector>      ::= key | key:arg | key:arg,key:arg,...
<assignment>    ::= key:value
```

Matching is **substring based**: each table entry stores the key string and
the driver does a prefix/`strstr`-style compare, so `displayId:4,` must end
with a comma or the next key.

### 4.2 Reply format

The reply is plain ASCII, for example:

```
status:0,displayId:1,displayId:4,
status:0,plugable:1,screencapture:1,
status:5,numBytes:16,bufferData:<raw bytes>
```

`status:N` is written by the handler; **N is not an NTSTATUS**. Truncate the
reply at the first NUL - the buffer is reused and stale bytes remain.

### 4.3 `get` table (`0x140303E50`)

| key | handler | notes |
|---|---|---|
| `displays` | `FUN_140115D30` | list of active `displayId` |
| `displaycaps` | `FUN_140115E40` | takes a `;`-separated list of sub-keys |
| `AuxRead` | `FUN_1401160B0` | AUX/DPCD read |
| `captureread` | `FUN_140116660` | **[unverified]** |

`displaycaps` sub-keys (`0x14030CCB0`):
`sharpness, warmness, hue, saturation, intensity, contrast, plugable, pcc,
igc, 3dlut, screencapture`.

Each returns **1 or 0 - a capability flag, not the current value.**

### 4.4 `set` table (`0x140303ED0`)

| key | handler | persists |
|---|---|---|
| `sharpness` | `FUN_1401131B0` | **yes** |
| `warmness` | `FUN_140113430` | **yes** |
| `hue` | `FUN_140113B50` | **yes** |
| `saturation` | `FUN_140113C50` | **yes** |
| `intensity` | `FUN_140113D50` | **yes** |
| `contrast` | `FUN_140113E50` | **yes** |
| `pcc` | `FUN_140113F50` | **yes** |
| `3dlut` | `FUN_1401145E0` | **yes** |
| `linkrate` | `FUN_140114D30` | no |
| `lanecount` | `FUN_140114E90` | no |
| `preemphasis` | `FUN_140114FF0` | no |
| `voltageswing` | `FUN_140115150` | no |
| `testpattern` | `FUN_1401152B0` | no |
| `igc` | `FUN_140114190` | no |
| `AuxWrite` | `FUN_1401128E0` | no |

"Persists" means the handler calls `FUN_140138458(displayId, 10, cfg, 0x14)`,
which writes the configuration to disk. **A wrong value survives reboot.**

Value ranges (from the `FUN_140115C10(value, min, max)` clamps):

| key | range | neutral |
|---|---|---|
| `hue` | -180 .. +180 | **0** |
| `contrast` | -100 .. +100 | **0** |
| `sharpness` | -100 .. +100 | **0** |

`set:` writes to an internal slot (display id 1/2/3/7) change panel state and
persist, so `qcdx_edid` refuses them unless `--allow-internal` is given, and
refuses the persisting keys unless `--persist-ok` is given.

### 4.5 Display slots

Slots are a flat index into a per-display array; the driver clamps
`idx > 10` to 0 and has **no hard-coded slot roles**. Two capability bits in
`DAT_140388A88[idx]` describe a slot:

```c
plugable      = (DAT_140388A88[idx] & 0x020000) != 0;   /* FUN_140116AF0, bit 17 */
screencapture = (DAT_140388A88[idx] & 0x4000000) != 0;  /* FUN_140116BC0, bit 26 */
```

Measured on the test machine:

| slot | plugable | screencapture | established by |
|---|---|---|---|
| 1 | 0 | 1 | the dump reports `[Display #1 - Primary] Connection: eDP` |
| 2, 3, 7 | 0 | **0** | never appear in any dump; both bits clear |
| 4 .. 10 | 1 | 1 | dumps report `Connection: DisplayPort (Type-C)` |

Only slot 1 is confirmed to be a real internal panel. Slots 2/3/7 look like
unused slots rather than panels, so "plugable == 0" is not the same statement
as "internal panel" - it only holds for slot 1 on this machine.

Writing to a `plugable == 0` slot is still refused by default: it is either the
internal panel or an absent slot, and neither is a sensible write target.

### 4.6 `AuxRead` operational constraints

All three were established empirically:

1. **`mode` must be 2** (raw AUX read). `mode:0` only writes `status:5` and
   returns no payload.
2. **The address must be decimal.** `AuxRead:0x100` is parsed as address 0;
   DPCD `0x100` must be written `AuxRead:256`.
3. **The target display must be active.** Once it idles out, `bufferData:` is
   empty and the call still reports success.

Reading DPCD `0x100` (256) yields the link configuration:

| DPCD | meaning |
|---|---|
| `0x100` | link bandwidth set - bits 4:0 rate code |
| `0x101` | lane count set - bits 4:0 |
| `0x1E` | HBR3 8.1 Gbps; `0x14` HBR2 5.4; `0x0A` HBR 2.7; `0x06` RBR 1.62 |

Note that a DP alt-mode converter may under-report `0x001` (max link rate);
the authoritative value is `0x100` plus the driver's own dump
(`Link Rate:` in `[Display #N - DisplayPort Configuration]`).

---

## 5. Driver bugs that will bite you

### 5.1 The scan window is 8 bytes short

Handlers for `AuxRead` and for every `set:` key receive the text advanced past
the `get:`/`set:` prefix, but the loop bound is the **full** command length.
The last 8 characters are therefore never scanned.

Symptom: the final key of a command is silently ignored, so
`get:displayId:4,AuxRead:256,mode:2,numBytes:16` returns an empty payload and
`set:displayId:1,hue:0` returns `status:2`.

Fix: append at least 8 filler characters so the last value still falls inside
the window. `qcdx_edid` appends 8 `X` automatically for `AuxRead` and `set:`.

### 5.2 `status` is not an error code

`AuxRead` initialises its reply to `status:5` and never changes it on success.
Do not interpret a non-zero `status` before checking whether a payload was
returned.

### 5.3 The reply buffer is not cleared

The driver writes its reply over a reused buffer; bytes from a previous,
longer reply remain. Always cut the reply at the first NUL.

---

## 6. Verifying a build

Addresses in this document are build specific. `tools/verify_build.py` checks
two fingerprints:

1. RVA `0x46E4A0` must start with `pacibsp` (`7F 23 03 D5`).
2. RVA `0x116234` must be an `adrp`+`add` pair resolving to the string `"mode"`
   (`0x1401E3A00`).

If either fails, the addresses here belong to a different build. Note that
DriverStore can hold several copies; always resolve the one that
`HKLM\SYSTEM\CurrentControlSet\Services\QCDX` actually loads.

`tools/audit.py` re-derives the three command tables, the five key strings and
the persistence classification straight from the binary and compares them with
this document; it should report "all checks passed".


