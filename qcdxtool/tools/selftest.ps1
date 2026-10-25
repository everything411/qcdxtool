<#
  selftest.ps1 - verify that the qcdxkm8380 private escape interface works
  on this machine.

  Only read-only commands are issued (displays / displaycaps / cmd 0x109 /
  dump). No EDID, link or display state is modified.

  Usage:
      .\selftest.ps1
      .\selftest.ps1 -SkipDump     # do not write C:\data\test
#>
param(
    [switch]$SkipDump
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-Exe {
    foreach ($p in @(
        (Join-Path $here '..\src\qcdx_edid.exe'),
        (Join-Path $here '..\bin\qcdx_edid.exe'),
        (Join-Path $here 'qcdx_edid.exe')
    )) {
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    return $null
}

$exe = Find-Exe
if (-not $exe) {
    Write-Host "qcdx_edid.exe not found. Build it first:" -ForegroundColor Red
    Write-Host "  csc /target:exe /out:qcdx_edid.exe /platform:anycpu qcdx_edid.cs"
    exit 1
}

function Run($arg) {
    $o = & $exe @arg 2>&1
    ($o | Select-String '^status' | Select-Object -First 1).Line
}

$pass = 0; $fail = 0
function Report($name, $ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    $tag = if ($ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1,-24} {2}" -f $tag, $name, $detail)
}

Write-Host "=== 1. build fingerprint ===" -ForegroundColor Cyan
$vb = Join-Path $here 'verify_build.py'
if (Test-Path $vb) {
    $out = python $vb 2>&1
    $match = $out | Select-String 'MATCH'
    if ($match) {
        foreach ($m in $match) { Write-Host ("       " + $m.Line.Trim()) }
        Report 'build' $true 'matches documented addresses'
    } else {
        foreach ($l in $out) { Write-Host ("       " + $l) }
        Report 'build' $false 'no matching build'
    }
} else {
    Report 'build' $false 'verify_build.py missing'
}

Write-Host "`n=== 1b. documentation audit ===" -ForegroundColor Cyan
$audit = Join-Path $here 'audit.py'
if (Test-Path $audit) {
    $ao = python $audit 2>&1
    $last = ($ao | Select-String 'all checks passed' | Select-Object -First 1).Line
    $okA = $null -ne $last
    if (-not $okA) { $last = ($ao | Select-String 'failed' | Select-Object -First 1).Line }
    Report 'audit' $okA ($(if ($last) { $last } else { 'no output' }))
} else {
    Report 'audit' $false 'audit.py missing'
}

Write-Host "`n=== 2. displays ===" -ForegroundColor Cyan
$list = Run @('--get', 'get:displayId')
if ($list) {
    $ids = [regex]::Matches($list, 'displayId:(\d+)') | ForEach-Object { [int]$_.Groups[1].Value }
    Write-Host ("       {0}" -f $list)
    Report 'displays' $true ("active: " + (($ids -join ', ')))
} else {
    Report 'displays' $false 'no response'
    $ids = @()
}

Write-Host "`n=== 3. displaycaps (1..10) ===" -ForegroundColor Cyan
for ($i = 1; $i -le 10; $i++) {
    $r = Run @('--get', "get:displayId:$i,displaycaps:plugable;screencapture")
    if ($r -and $r -ne 'status:2,') {
        Report "displaycaps $i" $true $r
    }
}

Write-Host "`n=== 4. cmd 0x109 (read-only query, 0..5) ===" -ForegroundColor Cyan
for ($i = 0; $i -le 5; $i++) {
    $o = & $exe --c2 0x109 $i 0 2>&1
    if (($o | Select-String '\[ok \] escape OK')) {
        Report "cmd0x109 idx=$i" $true 'escape OK'
    }
}

if (-not $SkipDump) {
    Write-Host "`n=== 5. diagnostics dump ===" -ForegroundColor Cyan
    $dir = 'C:\data\test'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    $name = 'selftest.txt'
    $o = & $exe --dump $name 2>&1
    $st = ($o | Select-String 'status @').Line
    $f = Join-Path $dir $name
    if (Test-Path $f) {
        $len = (Get-Item $f).Length
        Report 'dump' ($len -gt 0) "$st, $len bytes -> $f"
    } else {
        Report 'dump' $false "not created: $f"
    }
}

Write-Host ""
Write-Host ("result: {0} PASS / {1} FAIL" -f $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
exit $(if ($fail -eq 0) { 0 } else { 1 })
