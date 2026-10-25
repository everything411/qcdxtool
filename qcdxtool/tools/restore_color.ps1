<#
  restore_color.ps1 - reset the persisting color keys of one display to
  their neutral value.

  WHY THIS EXISTS
  ---------------
  The color setters (sharpness / warmness / hue / saturation / intensity /
  contrast / pcc / 3dlut) call FUN_140138458() on success, which asks the
  miniport settings API to store the configuration. The setter ignores the
  result, and no stored colour blob has been observed in that registry key, so
  the real persistence behaviour is unverified - but a wrong value can leave
  the panel tinted, so resetting is the safe move.

  Neutral values (from the clamp ranges in the setters):
      hue                    -180 .. +180,  neutral 0
      contrast / sharpness   -100 .. +100,  neutral 0

  The tool refuses these keys unless --persist-ok is passed, and refuses
  internal slots (displayId 1/2/3/7) unless --allow-internal is passed; this
  script passes both because resetting to neutral is the safe direction.

  NOTE: `get:displayId:N,displaycaps:hue` reports a CAPABILITY flag (1/0),
  not the current value. The only real confirmation is looking at the screen.

  Usage:
      .\restore_color.ps1 -Check          # read-only: show what is stored
      .\restore_color.ps1                 # display 1, hue/contrast/sharpness
      .\restore_color.ps1 -Index 4
      .\restore_color.ps1 -Keys hue,saturation
      .\restore_color.ps1 -WhatIf         # show the commands only

  WHERE THE VALUES LIVE
  ---------------------
      HKLM\SOFTWARE\QCOM\Drivers\DxKMD\Miniport\DISPLAY\Config
          SHRP  (4 bytes)   sharpness
          HSIC  (20 bytes)  header, hue, saturation, intensity, contrast

  -Check reads that key and decodes it, which is the only way to see the
  stored values - displaycaps reports capability flags, not current values.
#>
param(
    [int]$Index = 1,
    [string[]]$Keys = @('hue', 'contrast', 'sharpness'),
    [switch]$WhatIf,
    [switch]$Check
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgKey = 'HKLM:\SOFTWARE\QCOM\Drivers\DxKMD\Miniport\DISPLAY\Config'

# The driver stores the colour configuration here, keyed by 4-character tags.
# This is the only way to read back what was actually written: displaycaps
# reports capability flags, not values.
function Show-StoredConfig {
    if (-not (Test-Path $cfgKey)) {
        Write-Host "  $cfgKey not present - nothing has been stored." -ForegroundColor Yellow
        return $true
    }
    $k = Get-Item $cfgKey
    $neutral = $true

    $shrp = $k.GetValue('SHRP')
    if ($null -ne $shrp) {
        $v = [BitConverter]::ToInt32($shrp, 0)
        $ok = ($v -eq 0)
        if (-not $ok) { $neutral = $false }
        Write-Host ("  SHRP  sharpness   = {0}{1}" -f $v, $(if ($ok) { '' } else { '   <-- NOT NEUTRAL' })) `
            -ForegroundColor $(if ($ok) { 'Green' } else { 'Yellow' })
    } else {
        Write-Host "  SHRP  (absent = never written)" -ForegroundColor DarkGray
    }

    $hsic = $k.GetValue('HSIC')
    if ($null -ne $hsic -and $hsic.Length -ge 20) {
        $names = @('header', 'hue', 'saturation', 'intensity', 'contrast')
        for ($i = 0; $i -lt 5; $i++) {
            $v = [BitConverter]::ToInt32($hsic, $i * 4)
            if ($i -eq 0) {
                Write-Host ("  HSIC  {0,-11} = {1}   (header, not a user value)" -f $names[$i], $v) -ForegroundColor DarkGray
            } else {
                $ok = ($v -eq 0)
                if (-not $ok) { $neutral = $false }
                Write-Host ("  HSIC  {0,-11} = {1}{2}" -f $names[$i], $v, $(if ($ok) { '' } else { '   <-- NOT NEUTRAL' })) `
                    -ForegroundColor $(if ($ok) { 'Green' } else { 'Yellow' })
            }
        }
    } else {
        Write-Host "  HSIC  (absent = never written)" -ForegroundColor DarkGray
    }

    return $neutral
}

if ($Check) {
    Write-Host "=== stored colour configuration ===" -ForegroundColor Cyan
    Write-Host "  $cfgKey"
    $neutral = Show-StoredConfig
    Write-Host ""
    if ($neutral) {
        Write-Host "Neutral: every user-facing colour value is 0." -ForegroundColor Green
        exit 0
    }
    Write-Host "Not neutral. Run this script without -Check to reset the values." -ForegroundColor Yellow
    exit 1
}

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



