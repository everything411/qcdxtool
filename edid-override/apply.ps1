<#
  apply.ps1 - install and inject an EDID override into qcdxkm8380.

  The override lives in RAM only. The driver frees it when the display stops
  (unplug / power off), so it must be re-injected after every hotplug and
  after every reboot. There is no daemon: run this script when you need the
  override.

  ORDER MATTERS
  -------------
  The override can only be injected while the target display is STOPPED.
  The driver reads the slot when the display starts. So the sequence is:

      copy XML  ->  unplug display  ->  clear + load  ->  plug display back

  A same-boot `load` without a preceding `clear` may not replace an existing
  slot, so `clear` is always issued first.

  Usage:
      .\apply.ps1                                   # sample 4K100/4K120 file, slot 4
      .\apply.ps1 -File my.xml -Index 4
      .\apply.ps1 -Index 4 -Auto                    # skip the prompts
      .\apply.ps1 -Revert -Index 4                  # remove override, restore stock EDID

  Requires administrator only for writing C:\Windows\edidoverride.xml.
  The escape calls themselves need no elevation.
#>
param(
    [string]$File   = (Join-Path $PSScriptRoot 'samples\edidoverride_M.xml'),
    [int]$Index     = 4,
    [switch]$Auto,
    [switch]$Revert
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-Exe {
    foreach ($p in @(
        (Join-Path $here '..\qcdxtool\src\qcdx_edid.exe'),
        (Join-Path $here '..\qcdxtool\bin\qcdx_edid.exe')
    )) { if (Test-Path $p) { return (Resolve-Path $p).Path } }
    return $null
}

function Get-DisplayIds([string]$exe) {
    $s = (& $exe --get 'get:displayId' 2>&1 | Select-String '^status').Line
    if (-not $s) { return @() }
    return @([regex]::Matches($s, 'displayId:(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$exe = Find-Exe
if (-not $exe) {
    Write-Host "qcdx_edid.exe not found. Build it first (see qcdxtool/README.md)." -ForegroundColor Red
    exit 1
}

$target = "C:\Windows\edidoverride.xml"

if ($Revert) {
    Write-Host "=== revert ===" -ForegroundColor Cyan
    if (Test-Path $target) {
        if (-not (Test-Admin)) { Write-Host "  need administrator to remove $target" -ForegroundColor Red; exit 2 }
        Remove-Item $target -Force
        Write-Host "  removed $target"
    } else {
        Write-Host "  $target not present"
    }
    Write-Host "  clearing slot $Index"
    & $exe --index $Index --clear 2>&1 | Select-String 'cmd\] status' | ForEach-Object { '  ' + $_.Line }
    Write-Host ""
    Write-Host "Done. Re-plug the display to get the stock EDID back." -ForegroundColor Green
    exit 0
}

# ---- 1. install the XML -------------------------------------------------
Write-Host "=== 1. install override ===" -ForegroundColor Cyan
if (-not (Test-Path $File)) { Write-Host "  file not found: $File" -ForegroundColor Red; exit 1 }
if (-not (Test-Admin)) {
    Write-Host "  administrator required to write $target" -ForegroundColor Red
    Write-Host "  re-run from an elevated prompt, or copy the file yourself and rerun with -Auto"
    exit 2
}
Copy-Item $File $target -Force
Write-Host "  installed $File"
Write-Host "  -> $target"

# ---- 2. wait for the display to stop ------------------------------------
Write-Host ""
Write-Host "=== 2. stop the display ===" -ForegroundColor Cyan
$ids = Get-DisplayIds $exe
if ($ids -contains $Index) {
    Write-Host "  slot $Index is currently active." -ForegroundColor Yellow
    if (-not $Auto) {
        Write-Host "  Unplug the display (or power it off), then press Enter..."
        Read-Host | Out-Null
    } else {
        Write-Host "  -Auto given: waiting up to 60s for the display to disappear..."
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            if (-not ((Get-DisplayIds $exe) -contains $Index)) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    $ids = Get-DisplayIds $exe
    if ($ids -contains $Index) {
        Write-Host "  slot $Index is still active; cannot inject safely." -ForegroundColor Red
        Write-Host "  Unplug it and run this script again." -ForegroundColor Red
        exit 3
    }
}
Write-Host "  slot $Index is stopped."

# ---- 3. clear + load ----------------------------------------------------
Write-Host ""
Write-Host "=== 3. inject ===" -ForegroundColor Cyan
$out = & $exe --index $Index --clear 2>&1
($out | Select-String 'cmd\] status' | ForEach-Object { '  clear: ' + $_.Line.Trim() })
$out = & $exe --index $Index 2>&1
($out | Select-String 'cmd\] status' | ForEach-Object { '  load : ' + $_.Line.Trim() })

# ---- 4. plug back -------------------------------------------------------
Write-Host ""
Write-Host "=== 4. start the display ===" -ForegroundColor Cyan
if (-not $Auto) {
    Write-Host "  Plug the display back in, then press Enter..."
    Read-Host | Out-Null
}

# ---- 5. verify ----------------------------------------------------------
Write-Host ""
Write-Host "=== 5. verify ===" -ForegroundColor Cyan
$ids = Get-DisplayIds $exe
if (-not ($ids -contains $Index)) {
    Write-Host "  slot $Index is not active yet; plug the display in and re-run just this check." -ForegroundColor Yellow
    exit 4
}
& $exe --dump 'override_check.txt' 2>&1 | Out-Null
$f = 'C:\data\test\override_check.txt'
if (Test-Path $f) {
    $modes = Select-String -Path $f -Pattern ("Display-Mode#" + $Index + "-")
    Write-Host "  driver mode list for slot $Index ($($modes.Count) entries):"
    $modes | ForEach-Object { Write-Host ("   " + $_.Line.Trim()) }
} else {
    Write-Host "  dump not available" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Pick a mode in Settings > System > Display > Advanced display." -ForegroundColor Green
Write-Host "Note: the monitor OSD may round 119.88 to 119; the mode itself is exact." -ForegroundColor DarkGray

