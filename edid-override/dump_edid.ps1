<#
  dump_edid.ps1 - read the EDID the driver currently serves for a display
  child and write it to a file.

  Reading the registry value is also how you verify that an override is
  actually installed: its length and bytes must match the generated .bin.

  Usage:
      .\dump_edid.ps1                              # list candidate children
      .\dump_edid.ps1 -Instance 'HEC107E\3&9781174&8&UID1' -Out stock.bin
#>
param(
    [string]$Instance,
    [string]$Out = 'edid.bin'
)

$root = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'

if (-not $Instance) {
    Write-Host "Display children under $root :" -ForegroundColor Cyan
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
        $vendor = $_.PSChildName
        Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
            $inst = "$vendor\$($_.PSChildName)"
            $edid = (Get-ItemProperty (Join-Path $_.PSPath 'Device Parameters') -ErrorAction SilentlyContinue).EDID
            if ($edid) {
                $len = $edid.Length
                $tag = if ($len -ge 0x105 -and $edid[0x100] -eq 0x70) { 'DisplayID' } else { '' }
                Write-Host ("  {0,-40} {1,4} bytes  {2}" -f $inst, $len, $tag)
            }
        }
    }
    Write-Host ""
    Write-Host "Re-run with -Instance <one of the above> -Out <file>"
    exit 0
}

$key = Join-Path $root "$Instance\Device Parameters"
$edid = (Get-ItemProperty $key -ErrorAction SilentlyContinue).EDID
if (-not $edid) {
    Write-Host "no EDID at $key" -ForegroundColor Red
    exit 1
}
[IO.File]::WriteAllBytes((Join-Path $PWD $Out), [byte[]]$edid)
Write-Host ("wrote {0} ({1} bytes, {2} extension(s))" -f $Out, $edid.Length, $edid[126])
if ($edid.Length -ge 0x105 -and $edid[0x100] -eq 0x70) {
    $blk = $edid[0x105]
    Write-Host ("DisplayID extension present, first block tag 0x{0:X2}" -f $blk)
}
