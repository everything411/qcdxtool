<#
  apply.ps1 - install and inject an EDID override into qcdxkm8380.

  The override lives in RAM only. The driver reads it when the display starts
  and frees it when the display stops, so it must be re-injected after every
  hotplug and after every reboot.

  ORDER MATTERS
  -------------
  The override can only be injected while the target display is STOPPED,
  because the driver reads the slot when the display starts. So the sequence
  is always:

      copy XML  ->  stop the display  ->  clear + load  ->  start the display

  `clear` must precede `load`; a same-boot `load` alone may not replace an
  existing slot.

  Usage:
      .\apply.ps1 -Index 4                  # full run: install, inject, verify
      .\apply.ps1 -Index 4 -Auto            # same, but do not wait for Enter
      .\apply.ps1 -Quick -Index 4           # XML already installed: just re-inject
      .\apply.ps1 -Revert -Index 4          # remove the override

  Administrator is needed only to write C:\Windows\edidoverride.xml.
  The escape calls themselves need no elevation.
#>
param(
    [string]$File   = (Join-Path $PSScriptRoot 'samples\edidoverride_M.xml'),
    [int]$Index     = 4,
    [switch]$Auto,
    [switch]$Quick,
    [switch]$Revert
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = 'C:\Windows\edidoverride.xml'

function Find-Exe {
    foreach ($p in @(
        (Join-Path $here '..\qcdxtool\src\qcdx_edid.exe'),
        (Join-Path $here '..\qcdxtool\bin\qcdx_edid.exe')
    )) { if (Test-Path $p) { return (Resolve-Path $p).Path } }
    return $null
}

function Get-DisplayIds([string]$exePath) {
    $s = (& $exePath --get 'get:displayId' 2>&1 | Select-String '^status').Line
    if (-not $s) { return @() }
    return @([regex]::Matches($s, 'displayId:(\d+)') | ForEach-Object { [int]::Parse($_.Groups[1].Value) })
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Inject([string]$exePath, [int]$slot) {
    & $exePath --index $slot --clear 2>&1 | Select-String 'cmd\] status' | ForEach-Object { '  clear: ' + $_.Line.Trim() }
    & $exePath --index $slot         2>&1 | Select-String 'cmd\] status' | ForEach-Object { '  load : ' + $_.Line.Trim() }
}

$exe = Find-Exe
if (-not $exe) {
    Write-Host "qcdx_edid.exe not found. Build it first (see qcdxtool/README.md)." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- revert --
if ($Revert) {
    Write-Host "=== revert ===" -ForegroundColor Cyan
    if (Test-Path $target) {
        if (-not (Test-Admin)) {
            Write-Host "  administrator required to remove $target" -ForegroundColor Red
            exit 2
        }
        Remove-Item $target -Force
        Write-Host "  removed $target"
    } else {
        Write-Host "  $target not present"
    }
    Write-Host "  clearing slot $Index"
    & $exe --index $Index --clear 2>&1 | Select-String 'cmd\] status' | ForEach-Object { '  ' + $_.Line.Trim() }
    Write-Host ""
    Write-Host "Done. Re-plug the display to get the stock EDID back." -ForegroundColor Green
    exit 0
}

# ----------------------------------------------------------- quick path --
# The XML is already in place; only re-inject. No prompts, no admin needed.
if ($Quick) {
    Write-Host "=== quick re-inject (slot $Index) ===" -ForegroundColor Cyan
    if (-not (Test-Path $target)) {
        Write-Host "  $target is missing - run once without -Quick to install it." -ForegroundColor Red
        exit 1
    }
    if ((Get-DisplayIds $exe) -contains $Index) {
        Write-Host "  slot $Index is active. Unplug the display first: the driver reads the" -ForegroundColor Yellow
        Write-Host "  override when the display starts, so it cannot be replaced live." -ForegroundColor Yellow
        exit 3
    }
    Inject $exe $Index
    Write-Host ""
    Write-Host "  Plug the display back in." -ForegroundColor Green
    exit 0
}

# --------------------------------------------------------- 1. install XML --
Write-Host "=== 1. install override ===" -ForegroundColor Cyan
if (-not (Test-Path $File)) {
    Write-Host "  file not found: $File" -ForegroundColor Red
    exit 1
}
if (-not (Test-Admin)) {
    Write-Host "  administrator required to write $target" -ForegroundColor Red
    Write-Host "  re-run elevated, or copy the file yourself and then use -Quick"
    exit 2
}
Copy-Item $File $target -Force
Write-Host "  installed $File -> $target"

# -------------------------------------------------- 2. wait for it to stop --
Write-Host ""
Write-Host "=== 2. stop the display ===" -ForegroundColor Cyan
if ((Get-DisplayIds $exe) -contains $Index) {
    Write-Host "  slot $Index is currently active." -ForegroundColor Yellow
    if (-not $Auto) {
        Write-Host "  Unplug the display (or power it off), then press Enter..."
        Read-Host | Out-Null
    } else {
        Write-Host "  -Auto: waiting up to 60s for the display to disappear..."
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            if (-not ((Get-DisplayIds $exe) -contains $Index)) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    if ((Get-DisplayIds $exe) -contains $Index) {
        Write-Host "  slot $Index is still active; cannot inject safely." -ForegroundColor Red
        Write-Host "  Unplug it and re-run." -ForegroundColor Red
        exit 3
    }
}
Write-Host "  slot $Index is stopped."

# ------------------------------------------------------------- 3. inject --
Write-Host ""
Write-Host "=== 3. inject ===" -ForegroundColor Cyan
Inject $exe $Index

# --------------------------------------------------------- 4. start again --
Write-Host ""
Write-Host "=== 4. start the display ===" -ForegroundColor Cyan
if (-not $Auto) {
    Write-Host "  Plug the display back in, then press Enter..."
    Read-Host | Out-Null
}

# ------------------------------------------------------------- 5. verify --
Write-Host ""
Write-Host "=== 5. verify ===" -ForegroundColor Cyan
if (-not ((Get-DisplayIds $exe) -contains $Index)) {
    Write-Host "  slot $Index is not active yet; plug it in and check again with:" -ForegroundColor Yellow
    Write-Host "    .\apply.ps1 -Quick -Index $Index   (after unplugging)" -ForegroundColor Yellow
    exit 4
}

$dir = 'C:\data\test'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
& $exe --dump 'override_check.txt' 2>&1 | Out-Null
$dump = Join-Path $dir 'override_check.txt'
if (Test-Path $dump) {
    $modes = Select-String -Path $dump -Pattern ("Display-Mode#" + $Index + "-")
    Write-Host "  driver mode list for slot $Index ($($modes.Count) entries):"
    $modes | ForEach-Object { Write-Host ("   " + $_.Line.Trim()) }

    # also show what EDID the driver is serving, so a stale override is obvious
    $recent = Select-String -Path $dump -Pattern 'Raw EDID' -Context 0,1 | Select-Object -First 1
    if ($recent) { Write-Host ("  Raw EDID: " + $recent.Context.PostContext[0].Trim()) }
} else {
    Write-Host "  dump not available" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Pick a mode in Settings > System > Display > Advanced display." -ForegroundColor Green
Write-Host "The mode list above is the driver's own view; Windows derives its list from it." -ForegroundColor DarkGray
