<#
  probe_dp.ps1 - read-only probe of an external DisplayPort monitor.

  Collects:
    1. Displays the driver currently sees
    2. Per-slot attributes (internal vs external)
    3. DPCD 0x100 link configuration (rate / lane count) for external slots
    4. A diagnostics dump summary (resolution, refresh range, bandwidth)

  Strictly read-only: no EDID write, no link change, no color change.

  Requirements for DPCD reads:
    - AuxRead needs `mode: 2` (mode 0 returns nothing)
    - addresses must be DECIMAL (the driver does not parse 0x.. here)
    - the display must be active (it disappears from `displayId` when asleep)

  Usage:
      .\probe_dp.ps1
      .\probe_dp.ps1 -SkipDump
#>
param([switch]$SkipDump)

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

# DPCD 0x100[4:0] link-rate codes (DP 1.4)
$RATE = @{ 0x06 = 1.62; 0x0A = 2.70; 0x14 = 5.40; 0x1E = 8.10 }
$LANES = @{ 0x01 = 1; 0x02 = 2; 0x04 = 4; 0x08 = 8 }

function Get-Status([string]$text) {
    (& $exe --get $text 2>&1 | Select-String '^status').Line
}

function Read-Dpcd([int]$id, [int]$addr, [int]$len) {
    $o = & $exe --get "get:displayId:$id,AuxRead:$addr,mode:2,numBytes:$len" 2>&1
    $hex = @()
    $in = $false
    foreach ($l in $o) {
        if ($l -match '^\[auxdata (\d+) bytes\]') { $in = $true; continue }
        if ($in -and $l -match '\+0x[0-9A-F]+:\s+(.*)$') { $hex += ($matches[1].Trim() -split '\s+') }
    }
    return $hex
}

Write-Host "=== 1. displays ===" -ForegroundColor Cyan
$list = Get-Status 'get:displayId'
Write-Host "   $list"
$ids = [regex]::Matches($list, 'displayId:(\d+)') | ForEach-Object { [int]$_.Groups[1].Value }

Write-Host ""
Write-Host "=== 2. slot attributes ===" -ForegroundColor Cyan
$external = @()
for ($i = 1; $i -le 10; $i++) {
    $s = Get-Status "get:displayId:$i,displaycaps:plugable;screencapture"
    if ($s -match 'plugable:(\d)') {
        $p = [int]$matches[1]
        Write-Host ("   d{0,-2} {1}   {2}" -f $i, $(if ($p -eq 1) { 'external' } else { 'internal' }), $s)
        if ($p -eq 1) { $external += $i }
    }
}

Write-Host ""
Write-Host "=== 3. DPCD 0x100 on external slots ===" -ForegroundColor Cyan
if ($external.Count -eq 0) { Write-Host "   no external slot" -ForegroundColor Yellow }
foreach ($id in $external) {
    if ($ids -notcontains $id) {
        Write-Host "   d$id  inactive (not in the displayId list); DPCD read would be empty" -ForegroundColor Yellow
        continue
    }
    $b = Read-Dpcd $id 256 8
    if ($b.Count -ge 2) {
        $code = [Convert]::ToInt32($b[0], 16)
        $lane = [Convert]::ToInt32($b[1], 16) -band 0x1F
        $rateTxt = if ($RATE.ContainsKey($code)) { "$($RATE[$code]) Gbps" } else { "unknown (0x{0:X2})" -f $code }
        $laneTxt = if ($LANES.ContainsKey($lane)) { "$($LANES[$lane]) lane" } else { "unknown (0x{0:X2})" -f $lane }
        Write-Host ("   d{0}  DPCD 0x100-0x107: {1}" -f $id, ($b -join ' '))
        Write-Host ("        -> {0} x {1}" -f $rateTxt, $laneTxt) -ForegroundColor Green
        if ($RATE.ContainsKey($code) -and $LANES.ContainsKey($lane)) {
            Write-Host ("        effective bandwidth ~ {0:N2} Gbps (after 8b/10b)" -f ($RATE[$code] * 0.8 * $LANES[$lane]))
        }
    } else {
        Write-Host "   d$id  no data (display inactive?)" -ForegroundColor Yellow
    }
}

if (-not $SkipDump) {
    Write-Host ""
    Write-Host "=== 4. diagnostics dump ===" -ForegroundColor Cyan
    $dir = 'C:\data\test'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    & $exe --dump 'probe_dp.txt' 2>&1 | Out-Null
    $f = Join-Path $dir 'probe_dp.txt'
    if (Test-Path $f) {
        Write-Host "   $f  $((Get-Item $f).Length) bytes"
        Select-String -Path $f -Pattern 'Display #\d+ - |Connection:|Mode Set:|Resolution:|Refresh rate:|Link Rate:|Number of Lanes:|DSC Status:|Dynamic Refresh Rates:|Bandwidth Vote|Total Bandwidth Available' |
            ForEach-Object { Write-Host ("   " + $_.Line.TrimEnd()) }
    } else {
        Write-Host "   dump not created" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "done (read-only)." -ForegroundColor Green

