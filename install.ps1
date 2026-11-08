#Requires -Version 5.1
<#
.SYNOPSIS
    Install an AppleCursor scheme for the current user, without admin rights.

.DESCRIPTION
    install.inf needs an elevated install because it copies into %windir%\Cursors.
    This script takes the other route: the cursor files go to
    %LOCALAPPDATA%\Cursors\<theme>, the scheme is registered under HKCU, and it is
    applied immediately with SPI_SETCURSORS. No elevation, no reboot, no logoff.

    If the Windows build has not run yet it is invoked automatically, so
    `.\install.ps1` on a fresh clone is the whole install. The previous pointer
    settings are saved next to the theme and can be put back with -Restore.

.PARAMETER Scheme
    Scheme name from schemes.conf. Default: GitHub-Dark.

.PARAMETER Profile
    regular, large or extra-large. Default: regular.

.PARAMETER Scale
    Glyph size inside its slot; 0.7 matches the apparent size of a stock Windows
    pointer. Default: 1.

.PARAMETER Size
    Optional Windows pointer size (CursorBaseSize), e.g. 32. Left alone when omitted.

.PARAMETER System
    Copy the cursors into %windir%\Cursors instead of %LOCALAPPDATA%. Needs an
    elevated shell.

.PARAMETER Build
    Force a rebuild even when dist\windows\<theme> is present.

.PARAMETER SkipBuild
    Fail instead of building when the theme is missing.

.PARAMETER Uninstall
    Remove the scheme and its files, then fall back to a stock scheme.

.PARAMETER Restore
    Put back the pointer settings saved by an earlier install.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -Scheme Nord -Scale 0.7

.EXAMPLE
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Scheme = 'GitHub-Dark',
    [ValidateSet('regular', 'large', 'extra-large')]
    [string]$Profile = 'regular',
    [ValidateRange(0.25, 1.0)]
    [double]$Scale = 1.0,
    [int]$Size,
    [switch]$System,
    [switch]$Build,
    [switch]$SkipBuild,
    [switch]$Uninstall,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = $PSScriptRoot
$Theme = "AppleCursor-$Scheme"
$SchemeName = "$Theme Cursors"
$RegRoot = 'HKCU:\Control Panel\Cursors'
$RegSchemes = 'HKCU:\Control Panel\Cursors\Schemes'

# Windows resolves a scheme by position, so this order is fixed.
$Order = @(
    @('Arrow', 'Pointer.cur'), @('Help', 'Help.cur'), @('AppStarting', 'Work.ani'),
    @('Wait', 'Busy.ani'), @('Crosshair', 'Cross.cur'), @('IBeam', 'Text.cur'),
    @('NWPen', 'Handwriting.cur'), @('No', 'Unavailiable.cur'), @('SizeNS', 'Vert.cur'),
    @('SizeWE', 'Horz.cur'), @('SizeNWSE', 'Dng1.cur'), @('SizeNESW', 'Dng2.cur'),
    @('SizeAll', 'Move.cur'), @('UpArrow', 'Alternate.cur'), @('Hand', 'Link.cur'),
    @('Pin', 'Pin.cur'), @('Person', 'Person.cur')
)
$Extra = @(@('Grab', 'Grabbing.cur'), @('Pan', 'Pan.cur'))

if ($System) {
    $Destination = Join-Path $env:windir "Cursors\$SchemeName"
} else {
    $Destination = Join-Path $env:LOCALAPPDATA "Cursors\$Theme"
}
$Backup = Join-Path $Destination 'previous-scheme.json'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeCursor {
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint param, IntPtr data, uint winIni);
    // SPI_SETCURSORS. SPIF_UPDATEINIFILE is rejected in some contexts (the
    // registry is written here anyway), so fall back to SPIF_SENDCHANGE.
    public static bool Apply() {
        if (SystemParametersInfo(0x0057, 0, IntPtr.Zero, 3)) return true;
        return SystemParametersInfo(0x0057, 0, IntPtr.Zero, 2);
    }
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadImage(IntPtr h, string name, uint type, int cx, int cy, uint load);
    [DllImport("user32.dll")] public static extern bool DestroyCursor(IntPtr h);
    public static bool Loads(string path) {
        IntPtr h = LoadImage(IntPtr.Zero, path, 2, 0, 0, 0x10);
        if (h == IntPtr.Zero) return false;
        DestroyCursor(h);
        return true;
    }
}
'@

function Test-Elevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-PreviousState {
    if (Test-Path -LiteralPath $Backup) { return }
    $state = [ordered]@{
        capturedAt = (Get-Date).ToString('o')
        schemeName = (Get-Item $RegRoot).GetValue('')
        roles      = [ordered]@{}
    }
    foreach ($property in (Get-ItemProperty $RegRoot).PSObject.Properties) {
        if ($property.Name -notlike 'PS*') { $state.roles[$property.Name] = $property.Value }
    }
    if ($state.schemeName -and (Test-Path $RegSchemes)) {
        $state.schemeEntry = (Get-Item $RegSchemes).GetValue($state.schemeName)
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Backup -Encoding UTF8
}

function Restore-PreviousState {
    if (-not (Test-Path -LiteralPath $Backup)) { throw "nothing saved at $Backup" }
    $state = Get-Content -LiteralPath $Backup -Raw | ConvertFrom-Json
    New-Item -Path $RegSchemes -Force | Out-Null
    foreach ($name in $state.roles.PSObject.Properties.Name) {
        $value = $state.roles.$name
        if ($value -is [string] -and $value) { Set-ItemProperty -Path $RegRoot -Name $name -Value $value -Type String }
    }
    if ($state.schemeName) { Set-Item -Path $RegRoot -Value $state.schemeName }
    if ($state.schemeEntry) {
        New-ItemProperty -Path $RegSchemes -Name $state.schemeName -Value $state.schemeEntry -PropertyType String -Force | Out-Null
    }
    [void][NativeCursor]::Apply()
    "restored: $($state.schemeName)"
}

function Get-ThemeDirectory {
    $built = Join-Path $Root "dist\windows\$Theme"
    if ((Test-Path -LiteralPath $built) -and -not $Build) { return $built }
    if ($SkipBuild) { throw "missing $built (build it with tools\build-windows.ps1)" }

    $builder = Join-Path $Root 'tools\build-windows.ps1'
    $arguments = @{ Scheme = @($Scheme); Profile = $Profile; Scale = $Scale }
    if ($Build) { $arguments['Force'] = $true }
    Write-Host "building $Theme..."
    & $builder @arguments
    if (-not (Test-Path -LiteralPath $built)) { throw "build produced no $built" }
    return $built
}

function Install-Theme {
    $source = Get-ThemeDirectory
    # A theme on disk was built at whatever -Scale that build used; report that
    # rather than the number typed this time.
    $effectiveScale = $Scale
    $infoFile = Join-Path $source 'build.json'
    if (Test-Path -LiteralPath $infoFile) {
        $info = Get-Content -LiteralPath $infoFile -Raw | ConvertFrom-Json
        if ($null -ne $info.scale) {
            $effectiveScale = [double]$info.scale
            if ([math]::Abs($effectiveScale - $Scale) -gt 0.001) {
                Write-Warning ("dist\windows\$Theme was built at scale $effectiveScale; " +
                    "the -Scale $Scale was ignored. Add -Build to rebuild it.")
            }
        }
    }
    Save-PreviousState
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $source -File |
        Where-Object { $_.Extension -in '.cur', '.ani' } |
        Copy-Item -Destination $Destination -Force

    $paths = @()
    foreach ($pair in $Order) {
        $file = Join-Path $Destination $pair[1]
        if (-not (Test-Path -LiteralPath $file)) { throw "missing $file" }
        if (-not [NativeCursor]::Loads($file)) { throw "Windows rejects $file" }
        $paths += $file
        Set-ItemProperty -Path $RegRoot -Name $pair[0] -Value $file -Type String
    }
    foreach ($pair in $Extra) {
        $file = Join-Path $Destination $pair[1]
        if (Test-Path -LiteralPath $file) { Set-ItemProperty -Path $RegRoot -Name $pair[0] -Value $file -Type String }
    }

    New-Item -Path $RegSchemes -Force | Out-Null
    New-ItemProperty -Path $RegSchemes -Name $SchemeName -Value ($paths -join ',') -PropertyType String -Force | Out-Null
    Set-ItemProperty -Path $RegRoot -Name 'Scheme Source' -Value 1 -Type DWord
    Set-Item -Path $RegRoot -Value $SchemeName
    if ($PSBoundParameters.ContainsKey('Size')) {
        Set-ItemProperty -Path $RegRoot -Name 'CursorBaseSize' -Value $Size -Type DWord
    }

    [void][NativeCursor]::Apply()
    "installed: $SchemeName"
    "cursors  : $Destination"
    "scale    : $effectiveScale"
}

function Uninstall-Theme {
    $current = (Get-Item $RegRoot).GetValue('')
    if (Test-Path $RegSchemes) {
        Remove-ItemProperty -Path $RegSchemes -Name $SchemeName -ErrorAction SilentlyContinue
    }
    $stock = 'Windows Aero'
    $stockEntry = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\Cursors\Schemes').$stock
    if ($stockEntry) {
        New-ItemProperty -Path $RegSchemes -Name $stock -Value $stockEntry -PropertyType String -Force | Out-Null
        $stockPaths = $stockEntry -split ','
        $index = 0
        foreach ($pair in $Order) {
            if ($index -lt $stockPaths.Count -and $stockPaths[$index]) {
                Set-ItemProperty -Path $RegRoot -Name $pair[0] -Value $stockPaths[$index] -Type String
            }
            $index++
        }
        foreach ($pair in $Extra) {
            Remove-ItemProperty -Path $RegRoot -Name $pair[0] -ErrorAction SilentlyContinue
        }
        Set-Item -Path $RegRoot -Value $stock
        [void][NativeCursor]::Apply()
    }
    if ($current -eq $SchemeName) { Write-Host "switched to $stock" }
    Get-ChildItem -LiteralPath $Destination -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.cur', '.ani' } | Remove-Item -Force
    "uninstalled: $SchemeName"
}

if ($Uninstall) {
    Uninstall-Theme
} elseif ($Restore) {
    Restore-PreviousState
} else {
    Install-Theme
}
