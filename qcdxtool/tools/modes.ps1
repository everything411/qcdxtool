<#
  modes.ps1 - enumerate display modes through the Win32 display API.

  This is the *user-mode* view (what Windows offers), which is handy to
  compare against the driver's own view (`qcdx_edid --dump`, the
  "Mode List" section of each display).

  Usage:
      .\modes.ps1                 # all modes of every attached display
      .\modes.ps1 -Current        # only the current mode
      .\modes.ps1 -Device \\.\DISPLAY2
      .\modes.ps1 -Raw            # include RAWMODE entries
#>
param(
    [switch]$Current,
    [switch]$Raw,
    [string]$Device
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DispApi {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public uint dmFields;
    public int dmPositionX, dmPositionY;
    public uint dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public ushort dmLogPixels;
    public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool EnumDisplaySettingsEx(string dev, int modeNum, ref DEVMODE dm, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool EnumDisplayDevices(string dev, uint devNum, ref DISPLAY_DEVICE dd, uint flags);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
    public uint StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey;
  }
}
'@

function Get-DisplayModes([string]$dev, [uint32]$flags) {
    $list = [System.Collections.Generic.List[object]]::new()
    $dm = New-Object DispApi+DEVMODE
    for ($i = 0; $i -lt 500; $i++) {
        $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type]([DispApi+DEVMODE]))
        if (-not [DispApi]::EnumDisplaySettingsEx($dev, $i, [ref]$dm, $flags)) { break }
        $list.Add([pscustomobject]@{
            W = $dm.dmPelsWidth; H = $dm.dmPelsHeight
            Hz = $dm.dmDisplayFrequency; Bpp = $dm.dmBitsPerPel
        })
    }
    return $list
}

# Device names shift across hotplug, so probe DISPLAY1..16 and keep the ones
# that answer. (EnumDisplayDevices is not usable from a non-interactive
# session, so it is not used here.)
function Get-AttachedDisplays {
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -le 16; $i++) {
        $dev = "\\.\DISPLAY$i"
        $dm = New-Object DispApi+DEVMODE
        $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type]([DispApi+DEVMODE]))
        if ([DispApi]::EnumDisplaySettingsEx($dev, -1, [ref]$dm, 0)) { $out.Add($dev) }
    }
    return $out
}

$targets = if ($Device) { @($Device) } else { Get-AttachedDisplays }
if ($targets.Count -eq 0) {
    Write-Host "No attached display found." -ForegroundColor Yellow
    exit 1
}

foreach ($dev in $targets) {
    if ($Current) {
        $dm = New-Object DispApi+DEVMODE
        $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type]([DispApi+DEVMODE]))
        if ([DispApi]::EnumDisplaySettingsEx($dev, -1, [ref]$dm, 0)) {
            Write-Host ("{0}  current: {1}x{2}@{3}Hz {4}bpp" -f $dev, $dm.dmPelsWidth, $dm.dmPelsHeight, $dm.dmDisplayFrequency, $dm.dmBitsPerPel)
        }
        continue
    }

    $all = Get-DisplayModes $dev 0
    $uniq = $all | Sort-Object W, H, Hz -Unique
    Write-Host ("==== {0}   {1} modes ({2} distinct)" -f $dev, $all.Count, $uniq.Count) -ForegroundColor Cyan
    $uniq | Sort-Object W, H, Hz | ForEach-Object { "   {0}x{1}@{2}" -f $_.W, $_.H, $_.Hz }

    if ($Raw) {
        $rawModes = Get-DisplayModes $dev 2
        $rawu = $rawModes | Sort-Object W, H, Hz -Unique
        Write-Host ("   -- raw mode entries: {0} distinct" -f $rawu.Count) -ForegroundColor DarkGray
        $rawu | Sort-Object W, H, Hz | ForEach-Object { "   {0}x{1}@{2}" -f $_.W, $_.H, $_.Hz }
    }
}



