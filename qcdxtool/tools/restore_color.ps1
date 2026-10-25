<#
  restore_color.ps1 - reset the persisting color keys of one display to
  their neutral value.

  WHY THIS EXISTS
  ---------------
  The color setters (sharpness / warmness / hue / saturation / intensity /
  contrast / pcc / 3dlut) call FUN_140138458() on success, which writes the
  configuration to disk. A wrong value therefore SURVIVES A REBOOT and can
  leave the panel tinted.

  Neutral values (from the clamp ranges in the setters):
      hue                    -180 .. +180,  neutral 0
      contrast / sharpness   -100 .. +100,  neutral 0

  The tool refuses these keys unless --persist-ok is passed, and refuses
  internal slots (displayId 1/2/3/7) unless --allow-internal is passed; this
  script passes both because resetting to neutral is the safe direction.

  NOTE: `get:displayId:N,displaycaps:hue` reports a CAPABILITY flag (1/0),
  not the current value. The only real confirmation is looking at the screen.

  Usage:
      .\restore_color.ps1                 # display 1, hue/contrast/sharpness
      .\restore_color.ps1 -Index 4
      .\restore_color.ps1 -Keys hue,saturation
      .\restore_color.ps1 -WhatIf         # show the commands only
#>
param(
    [int]$Index = 1,
    [string[]]$Keys = @('hue', 'contrast', 'sharpness'),
    [switch]$WhatIf
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-Exe {
    foreach ($p in @(
        (Join-Path $here '..\src\qcdx_edid.exe'),
        (Join-Path $here '..\bin\qcdx_edid.exe'),
        (Join-Path $here 'qcdx_edid.exe')
    )) { if (Test-Path $p) { return (Resolve-Path $p).Path } }
    return $null
}

$exe = Find-Exe
if (-not $exe) { Write-Host "qcdx_edid.exe not found; build it first." -ForegroundColor Red; exit 1 }

Write-Host "Resetting color keys on displayId $Index : $($Keys -join ', ')" -ForegroundColor Cyan
Write-Host "Each key is written as 0 (neutral). This value persists across reboot." -ForegroundColor DarkGray

$failed = 0
$ran = 0
foreach ($k in $Keys) {
    $expr = "set:displayId:$Index,$k`:0"
    if ($WhatIf) {
        Write-Host ("   would run: qcdx_edid --persist-ok --allow-internal --get `"$expr`"")
        continue
    }
    $ran++
    $o = & $exe --persist-ok --allow-internal --get $expr 2>&1
    $s = ($o | Select-String '^status' | Select-Object -First 1).Line
    if ($s -match '^status:0') {
        Write-Host ("   {0,-12} {1}" -f $k, $s) -ForegroundColor Green
    } else {
        Write-Host ("   {0,-12} {1}" -f $k, $s) -ForegroundColor Yellow
        $failed++
    }
}

Write-Host ""
if ($ran -eq 0) {
    Write-Host "Nothing was written (-WhatIf)." -ForegroundColor Yellow
} elseif ($failed -eq 0) {
    Write-Host "All keys returned status 0." -ForegroundColor Green
    Write-Host "Look at the screen to confirm; displaycaps only reports capability flags." -ForegroundColor DarkGray
} else {
    Write-Host "$failed key(s) did not return status 0 - inspect the output above." -ForegroundColor Yellow
}
exit $(if ($failed -eq 0) { 0 } else { 1 })

