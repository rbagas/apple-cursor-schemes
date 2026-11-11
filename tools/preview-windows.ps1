#Requires -Version 5.1
<#
.SYNOPSIS
    Render a contact sheet of the built Windows cursors, so a new colour scheme
    can be judged before installing it.

.DESCRIPTION
    Draws every pointer role of one or more schemes onto a single PNG, each at the
    size Windows actually renders it, with the role name underneath. The theme is
    built first if dist\windows lacks it.

.PARAMETER Scheme
    One or more scheme names from schemes.conf. Default: every scheme.

.PARAMETER Size
    Tile size in pixels. Default 64, the size a 100% scale desktop asks for.

.PARAMETER Output
    PNG path. Default: dist\windows\preview-<scheme>.png per scheme, or
    dist\windows\preview.png when several are rendered.

.EXAMPLE
    .\tools\preview-windows.ps1 -Scheme Gruvbox-Dark

.EXAMPLE
    .\tools\preview-windows.ps1 -Size 32 -Scheme Nord -Output nord-32.png
#>
[CmdletBinding()]
param(
    [string[]]$Scheme,
    [ValidateRange(16, 256)]
    [int]$Size = 64,
    [ValidateSet('regular', 'large', 'extra-large')]
    [string]$Profile = 'regular',
    [ValidateRange(0.25, 1.0)]
    [double]$Scale = 1.0,
    [string]$Output
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

$Root = Split-Path -Parent $PSScriptRoot

# Same order as the Mouse Properties dialog, plus the two roles it hides.
$Roles = @(
    @('Arrow', 'Pointer.cur'), @('Help', 'Help.cur'), @('AppStarting', 'Work.ani'),
    @('Wait', 'Busy.ani'), @('Crosshair', 'Cross.cur'), @('IBeam', 'Text.cur'),
    @('NWPen', 'Handwriting.cur'), @('No', 'Unavailiable.cur'), @('SizeNS', 'Vert.cur'),
    @('SizeWE', 'Horz.cur'), @('SizeNWSE', 'Dng1.cur'), @('SizeNESW', 'Dng2.cur'),
    @('SizeAll', 'Move.cur'), @('UpArrow', 'Alternate.cur'), @('Hand', 'Link.cur'),
    @('Pin', 'Pin.cur'), @('Person', 'Person.cur'), @('Grab', 'Grabbing.cur'),
    @('Pan', 'Pan.cur'), @('Zoom-in', 'Zoom-in.cur'), @('Zoom-out', 'Zoom-out.cur')
)

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CursorDraw {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadImage(IntPtr h, string name, uint type, int cx, int cy, uint load);
    [DllImport("user32.dll")] public static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr hIcon, int w, int h, int frame, IntPtr brush, int flags);
    [DllImport("user32.dll")] public static extern bool DestroyCursor(IntPtr h);
}
'@

function Get-SchemeTable {
    $table = @{}
    foreach ($line in (Get-Content -LiteralPath (Join-Path $Root 'schemes.conf'))) {
        if ($line -match '^\s*#' -or $line -notmatch '\S') { continue }
        $parts = $line -split '\|'
        $table[$parts[0].Trim()] = @{ Fill = $parts[1].Trim(); Outline = $parts[2].Trim() }
    }
    $table
}

function Get-ThemeDirectory {
    param([string]$Name)
    $built = Join-Path $Root "dist\windows\AppleCursor-$Name"
    if (Test-Path -LiteralPath $built) { return $built }
    Write-Host "building AppleCursor-$Name..."
    & (Join-Path $PSScriptRoot 'build-windows.ps1') -Scheme $Name -Profile $Profile -Scale $Scale
    if (-not (Test-Path -LiteralPath $built)) { throw "build produced no $built" }
    $built
}

$schemes = Get-SchemeTable
$requested = @()
if ($Scheme) {
    # Accept -Scheme A,B even when the caller passes one comma-joined string
    # (powershell.exe -File does not split on commas).
    foreach ($entry in $Scheme) {
        $requested += @($entry -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
} else {
    $requested = @($schemes.Keys | Sort-Object)
}
$wanted = @($requested)
foreach ($name in $wanted) {
    if (-not $schemes.ContainsKey($name)) { throw "unknown scheme: $name" }
}

$cell = $Size
$label = 20
$gutter = 16
$columns = 5
$pad = 16
$rows = [int][math]::Ceiling($Roles.Count / $columns)
$header = 58
# Every role is drawn twice — once on a light tile, once on a dark one — because
# a dark body disappears on dark and a white body disappears on white.
$pair = $cell * 2

$tiles = @()
foreach ($name in $wanted) {
    $directory = Get-ThemeDirectory -Name $name
    $sheetWidth = $pad * 2 + $columns * ($pair + $gutter) - $gutter
    $sheetHeight = $header + $rows * ($cell + $label + $gutter) - $gutter + $pad
    $sheet = [System.Drawing.Bitmap]::new($sheetWidth, $sheetHeight)
    $graphics = [System.Drawing.Graphics]::FromImage($sheet)
    try {
        $graphics.Clear([System.Drawing.ColorTranslator]::FromHtml('#0d1117'))
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

        $titleFont = [System.Drawing.Font]::new('Segoe UI Semibold', 15)
        $labelFont = [System.Drawing.Font]::new('Segoe UI', 8.5)
        $smallFont = [System.Drawing.Font]::new('Segoe UI', 9)
        $titleBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#e6edf3'))
        $labelBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#8b949e'))
        $muted = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#586069'))
        $lightBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#f0f0f0'))
        $darkBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#161b22'))
        $edgePen = [System.Drawing.Pen]::new([System.Drawing.ColorTranslator]::FromHtml('#30363d'))
        try {
            $info = $schemes[$name]
            $graphics.DrawString("AppleCursor-$name", $titleFont, $titleBrush, $pad, 12)
            $graphics.DrawString(
                ("$($info.Fill) body, $($info.Outline) edge, drawn at ${cell} px on light and dark"),
                $smallFont, $labelBrush, $pad, 36)

            for ($index = 0; $index -lt $Roles.Count; $index++) {
                $role = $Roles[$index][0]
                $file = Join-Path $directory $Roles[$index][1]
                $column = $index % $columns
                $row = [int][math]::Floor($index / $columns)
                $x = $pad + $column * ($pair + $gutter)
                $y = $header + $row * ($cell + $label + $gutter)

                $graphics.FillRectangle($lightBrush, $x, $y, $cell, $cell)
                $graphics.FillRectangle($darkBrush, $x + $cell, $y, $cell, $cell)
                $graphics.DrawRectangle($edgePen, $x, $y, $pair - 1, $cell - 1)

                $handle = if (Test-Path -LiteralPath $file) {
                    [CursorDraw]::LoadImage([IntPtr]::Zero, $file, 2, $cell, $cell, 0x10)
                } else { [IntPtr]::Zero }

                if ($handle -ne [IntPtr]::Zero) {
                    $hdc = $graphics.GetHdc()
                    try {
                        [void][CursorDraw]::DrawIconEx($hdc, $x, $y, $handle, $cell, $cell, 0, [IntPtr]::Zero, 3)
                        [void][CursorDraw]::DrawIconEx($hdc, $x + $cell, $y, $handle, $cell, $cell, 0, [IntPtr]::Zero, 3)
                    } finally { $graphics.ReleaseHdc($hdc) }
                    [void][CursorDraw]::DestroyCursor($handle)
                } else {
                    $note = if (Test-Path -LiteralPath $file) { 'load failed' } else { 'missing' }
                    $graphics.DrawString($note, $labelFont, $muted, $x + 4, $y + 4)
                }

                $graphics.DrawString($role, $labelFont, $labelBrush, $x + 1, $y + $cell + 3)
            }
        } finally {
            $titleFont.Dispose(); $labelFont.Dispose(); $smallFont.Dispose()
            $titleBrush.Dispose(); $labelBrush.Dispose(); $muted.Dispose()
            $lightBrush.Dispose(); $darkBrush.Dispose(); $edgePen.Dispose()
        }
    } finally { $graphics.Dispose() }

    $target = if (-not $Output) {
        Join-Path $Root "dist\windows\preview-$name.png"
    } elseif ($wanted.Count -eq 1) {
        $Output
    } else {
        # One output path for several schemes: suffix each with its name.
        $folder = Split-Path -Parent $Output
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($Output)
        Join-Path $folder "$stem-$name$([System.IO.Path]::GetExtension($Output))"
    }
    $parent = Split-Path -Parent $target
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $sheet.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
    $sheet.Dispose()
    $tiles += $target
}
$tiles
