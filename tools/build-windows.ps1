#Requires -Version 5.1
<#
.SYNOPSIS
    Build the Windows cursor sets from the SVG sources without bash, librsvg or
    WSL: the only dependency is Microsoft Edge, which ships with Windows.

.DESCRIPTION
    build.sh is the canonical builder and needs rsvg-convert + xcursorgen, so on
    Windows it only runs under MSYS2/WSL. This script produces the same
    dist/windows/<theme>/ payload (CUR, ANI, install.inf) straight from the
    SVGs, rasterising through Edge's headless renderer.

    Rendering is batched: every image of one size goes into a single HTML page of
    fixed-size tiles, one Edge screenshot captures the page, and the tiles are
    sliced back out. The whole regular profile is 7 screenshots, not 194.

.PARAMETER Scheme
    One or more scheme names from schemes.conf. Default: every scheme.

.PARAMETER Profile
    regular (22-171 px), large (26-205 px) or extra-large (32-256 px).

.PARAMETER Scale
    Shrink the glyph inside its slot, 0 < Scale <= 1. The artwork fills its 256
    canvas more than a stock Windows pointer does (21x29 px against 12x19 in a
    32 px slot), so 0.7 lands it at the familiar size. Hotspots stay anchored.

.PARAMETER Output
    Output root. Default: <repo>/dist/windows.

.EXAMPLE
    .\tools\build-windows.ps1 -Scheme GitHub-Dark

.EXAMPLE
    .\tools\build-windows.ps1 -Profile large -Scale 0.8
#>
[CmdletBinding()]
param(
    [string[]]$Scheme,
    [ValidateSet('regular', 'large', 'extra-large')]
    [string]$Profile = 'regular',
    [ValidateRange(0.25, 1.0)]
    [double]$Scale = 1.0,
    [string]$Output,
    [switch]$Force,
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

$Root = Split-Path -Parent $PSScriptRoot
$Canvas = 256
$AniRate = 2          # jiffies per frame (1/60 s), as build.sh pins it
$ProfileFile = Join-Path $Root "configs\win_$(@{ regular = 'rg'; large = 'lg'; 'extra-large' = 'xl' }[$Profile]).build.toml"
if (-not $Output) { $Output = Join-Path $Root 'dist\windows' }

# Windows reads the pointer roles positionally out of the Schemes registry value,
# in this order. Everything else in the value is ignored.
$SchemeOrder = @(
    @('Arrow', 'Pointer.cur'), @('Help', 'Help.cur'), @('AppStarting', 'Work.ani'),
    @('Wait', 'Busy.ani'), @('Crosshair', 'Cross.cur'), @('IBeam', 'Text.cur'),
    @('NWPen', 'Handwriting.cur'), @('No', 'Unavailiable.cur'), @('SizeNS', 'Vert.cur'),
    @('SizeWE', 'Horz.cur'), @('SizeNWSE', 'Dng1.cur'), @('SizeNESW', 'Dng2.cur'),
    @('SizeAll', 'Move.cur'), @('UpArrow', 'Alternate.cur'), @('Hand', 'Link.cur'),
    @('Pin', 'Pin.cur'), @('Person', 'Person.cur')
)
# Roles Windows stores but the Mouse dialog does not show.
$ExtraRoles = @(@('Grab', 'Grabbing.cur'), @('Pan', 'Pan.cur'))

function Write-Step { param([string]$Message) Write-Host "  $Message" }

# --------------------------------------------------------------------- config
function Read-TomlFile {
    param([string]$Path)
    $sections = @{ root = @{} }
    $current = 'root'
    $pending = $null
    foreach ($rawLine in (Get-Content -LiteralPath $Path)) {
        $line = ($rawLine -replace "\s+#.*$", '').Trim()
        if (-not $line) { continue }
        if ($pending) {
            $pending.value += ' ' + $line
            if (($pending.value.ToCharArray() | Where-Object { $_ -eq '[' }).Count -le
                ($pending.value.ToCharArray() | Where-Object { $_ -eq ']' }).Count) {
                $sections[$current][$pending.key] = ConvertFrom-TomlValue $pending.value
                $pending = $null
            }
            continue
        }
        if ($line -match '^\[(.+)\]$') {
            $current = $Matches[1].Trim()
            if (-not $sections.ContainsKey($current)) { $sections[$current] = @{} }
            continue
        }
        if ($line -notmatch '^([^=]+)=(.*)$') { continue }
        $key = $Matches[1].Trim()
        $value = $Matches[2].Trim()
        if ($value.StartsWith('[') -and -not $value.EndsWith(']')) {
            $pending = @{ key = $key; value = $value }
            continue
        }
        $sections[$current][$key] = ConvertFrom-TomlValue $value
    }
    if ($pending) { $sections[$current][$pending.key] = ConvertFrom-TomlValue $pending.value }
    $sections
}

function ConvertFrom-TomlValue {
    param([string]$Text)
    $Text = $Text.Trim()
    if ($Text.StartsWith('[')) {
        $inner = $Text.Trim('[', ']').Trim()
        if (-not $inner) { return @() }
        return @($inner -split ',' | ForEach-Object {
                $v = $_.Trim()
                if ($v -match "^['""](.*)['""]$") { $Matches[1] } else { [int]$v }
            })
    }
    if ($Text -match "^['""](.*)['""]$") { return $Matches[1] }
    if ($Text -match '^-?\d+$') { return [int]$Text }
    return $Text
}

# ---------------------------------------------------------------------- plans
function Get-SchemeList {
    $out = @()
    foreach ($line in (Get-Content -LiteralPath (Join-Path $Root 'schemes.conf'))) {
        if ($line -match '^\s*#' -or $line -notmatch '\S') { continue }
        $parts = $line -split '\|'
        $out += [pscustomobject]@{
            Name    = $parts[0].Trim()
            Fill    = $parts[1].Trim()
            Outline = $parts[2].Trim()
        }
    }
    $out
}

function Get-Frames {
    param([string]$Png)
    if ($Png.EndsWith('-*.png')) {   # literal '-*.png' like the bash case pattern
        $dir = Join-Path $Root ('svg\' + ($Png -replace '-\*\.png$', ''))
        return @(Get-ChildItem -LiteralPath $dir -Filter '*.svg' | Sort-Object Name | ForEach-Object { $_.FullName })
    }
    return @((Join-Path $Root ('svg\' + ($Png -replace '\.png$', '.svg'))))
}

function Get-CursorPlan {
    param([string]$ConfigPath)
    $toml = Read-TomlFile -Path $ConfigPath
    $fallback = $toml['cursors.fallback_settings']
    $sizes = @($fallback['win_sizes'])
    $plan = @()
    foreach ($name in $toml.Keys) {
        if (-not $name.StartsWith('cursors.') -or $name -eq 'cursors.fallback_settings') { continue }
        $section = $toml[$name]
        if (-not $section.ContainsKey('win_name')) { continue }
        $frames = @(Get-Frames -Png $section['png'])
        $override = $section['win_sizes']
        $plan += [pscustomobject]@{
            Cursor   = $name.Substring('cursors.'.Length)
            Role     = $section['win_name']
            Frames   = $frames
            HotX     = if ($section.ContainsKey('x_hotspot')) { [int]$section['x_hotspot'] } else { [int]$fallback['x_hotspot'] }
            HotY     = if ($section.ContainsKey('y_hotspot')) { [int]$section['y_hotspot'] } else { [int]$fallback['y_hotspot'] }
            Sizes    = if ($override) { @([int]$override) } else { $sizes }
            Animated = $frames.Count -gt 1
        }
    }
    , @{ Sizes = $sizes; Cursors = $plan }
}

function Get-WinHotspot {
    param([int]$Hot, [int]$Size)
    $value = [math]::Floor((($Hot * $Size) - 1) / $Canvas)
    [math]::Max(0, [math]::Min($Size - 1, [int]$value))
}

# ------------------------------------------------------------------- renderer
function Find-Edge {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($path in $candidates) { if (Test-Path -LiteralPath $path) { return $path } }
    $app = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe" -ErrorAction SilentlyContinue
    if ($app) { return $app.FullName }
    throw 'Microsoft Edge not found; it is required to rasterise the SVGs.'
}

function Get-ShortHash {
    param([string]$Text, [int]$Length = 40)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hex = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))
    } finally { $sha.Dispose() }
    ($hex -replace '-', '').ToLowerInvariant().Substring(0, $Length)
}

function Get-TintedSvg {
    param([string]$Path, [string]$Fill, [string]$Outline, [string]$CacheDir)
    $key = Get-ShortHash -Text "$Path|$Fill|$Outline"
    $target = Join-Path $CacheDir "$key.svg"
    if (-not $Force -and (Test-Path -LiteralPath $target)) { return $target }
    $text = Get-Content -LiteralPath $Path -Raw
    $text = $text -replace '(?i)#00FF00', $Fill -replace '(?i)#0000FF', $Outline
    Set-Content -LiteralPath $target -Value $text -Encoding UTF8 -NoNewline
    $target
}

function Invoke-EdgeScreenshot {
    param([string]$Edge, [string]$Url, [string]$PngPath, [int]$Width, [int]$Height, [string]$ProfileDir)
    if (Test-Path -LiteralPath $PngPath) { Remove-Item -LiteralPath $PngPath -Force }
    $arguments = @(
        '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
        '--no-default-browser-check', '--disable-extensions', '--force-device-scale-factor=1',
        '--default-background-color=00000000',
        "--user-data-dir=$ProfileDir",
        "--window-size=$Width,$Height",
        '--virtual-time-budget=5000',
        "--screenshot=$PngPath",
        $Url
    )
    $process = Start-Process -FilePath $Edge -ArgumentList ($arguments | ForEach-Object {
            if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
        }) -NoNewWindow -PassThru -Wait `
        -RedirectStandardError (Join-Path $ProfileDir 'edge.log')
    if (-not (Test-Path -LiteralPath $PngPath)) {
        $log = Get-Content -LiteralPath (Join-Path $ProfileDir 'edge.log') -Raw -ErrorAction SilentlyContinue
        throw "Edge produced no screenshot for $Url`n$log"
    }
    $process.ExitCode | Out-Null
}

function ConvertTo-DataUri {
    param([string]$SvgPath)
    $bytes = [System.IO.File]::ReadAllBytes($SvgPath)
    'data:image/svg+xml;base64,' + [Convert]::ToBase64String($bytes)
}

# One page per size: a grid of fixed tiles, captured once and sliced back out.
# Tiles are rendered at Super times the cursor size and downscaled here. That
# keeps the glyph geometrically honest (Skia mis-scales SVG images in boxes
# below ~30 px) and gives the small sizes the same antialiasing as the librsvg
# path in build.sh.
function Invoke-SizeBatch {
    param([string]$Edge, [hashtable]$Tiles, [int]$Size, [string]$WorkDir, [string]$ProfileDir, [double]$Scale)

    $super = 4
    $tile = $Size * $super
    $items = @($Tiles.Values)
    if ($items.Count -eq 0) { return }
    $columns = [int][math]::Min(8, $items.Count)
    $rows = [int][math]::Ceiling($items.Count / $columns)
    $width = $columns * $tile
    $height = $rows * $tile

    $glyph = [math]::Max(1, [int][math]::Round($Size * $Scale * $super))
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}img{position:absolute}</style></head><body>')
    for ($i = 0; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        $left = ($i % $columns) * $tile + [int][math]::Round(($item.HotX * $Size * (1 - $Scale) * $super) / $Canvas)
        $top = [math]::Floor($i / $columns) * $tile + [int][math]::Round(($item.HotY * $Size * (1 - $Scale) * $super) / $Canvas)
        [void]$builder.AppendLine("<img src=`"$(ConvertTo-DataUri $item.Svg)`" style=`"left:${left}px;top:${top}px;width:${glyph}px;height:${glyph}px`">")
    }
    [void]$builder.AppendLine('</body></html>')

    $pageFile = Join-Path $WorkDir "page-$Size.html"
    Set-Content -LiteralPath $pageFile -Value $builder.ToString() -Encoding UTF8
    $shot = Join-Path $WorkDir "page-$Size.png"
    Invoke-EdgeScreenshot -Edge $Edge -Url ('file:///' + ($pageFile -replace '\\', '/')) `
        -PngPath $shot -Width $width -Height $height -ProfileDir $ProfileDir

    $format = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    $stream = [System.IO.File]::OpenRead($shot)
    try {
        $loaded = [System.Drawing.Image]::FromStream($stream)
        $pageBitmap = [System.Drawing.Bitmap]::new($width, $height, $format)
        $graphics = [System.Drawing.Graphics]::FromImage($pageBitmap)
        try { $graphics.DrawImageUnscaled($loaded, 0, 0) } finally { $graphics.Dispose() }
        $loaded.Dispose()
    } finally { $stream.Dispose() }

    if ($pageBitmap.Width -ne $width -or $pageBitmap.Height -ne $height) {
        throw "page $Size px rendered as $($pageBitmap.Width)x$($pageBitmap.Height), expected ${width}x${height}"
    }
    $locked = $pageBitmap.LockBits([System.Drawing.Rectangle]::new(0, 0, $width, $height),
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $format)
    try {
        $pageStride = $locked.Stride
        $pageBytes = New-Object byte[] ($pageStride * $height)
        [System.Runtime.InteropServices.Marshal]::Copy($locked.Scan0, $pageBytes, 0, $pageBytes.Length)
    } finally { $pageBitmap.UnlockBits($locked) }

    $rowBytes = $tile * 4
    $premultiplied = [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb
    for ($i = 0; $i -lt $items.Count; $i++) {
        $srcX = ($i % $columns) * $tile
        $srcY = [int]([math]::Floor($i / $columns)) * $tile
        $crop = [System.Drawing.Bitmap]::new($tile, $tile, $format)
        $target = $crop.LockBits([System.Drawing.Rectangle]::new(0, 0, $tile, $tile),
            [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $format)
        try {
            for ($row = 0; $row -lt $tile; $row++) {
                $source = ($srcY + $row) * $pageStride + $srcX * 4
                $destination = [IntPtr]($target.Scan0.ToInt64() + $row * $target.Stride)
                [System.Runtime.InteropServices.Marshal]::Copy($pageBytes, $source, $destination, $rowBytes)
            }
        } finally { $crop.UnlockBits($target) }

        # Downscale in premultiplied space so the soft shadow edges do not fringe.
        $scaled = [System.Drawing.Bitmap]::new($Size, $Size, $premultiplied)
        $graphics = [System.Drawing.Graphics]::FromImage($scaled)
        try {
            $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
            $graphics.DrawImage($crop, [System.Drawing.Rectangle]::new(0, 0, $Size, $Size),
                [System.Drawing.Rectangle]::new(0, 0, $tile, $tile), [System.Drawing.GraphicsUnit]::Pixel)
        } finally { $graphics.Dispose() }
        $crop.Dispose()
        $scaled.Save($items[$i].Target, [System.Drawing.Imaging.ImageFormat]::Png)
        $scaled.Dispose()
    }
    $pageBitmap.Dispose()
}

# ------------------------------------------------------------------ containers
function New-CursorBytes {
    param([array]$Entries) # @{ Size; HotX; HotY; Png (bytes) }
    $count = $Entries.Count
    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream)
    try {
        $writer.Write([uint16]0); $writer.Write([uint16]2); $writer.Write([uint16]$count)
        $offset = 6 + 16 * $count
        foreach ($entry in $Entries) {
            $dim = if ($entry.Size -ge 256) { 0 } else { $entry.Size }
            $writer.Write([byte]$dim); $writer.Write([byte]$dim)
            $writer.Write([byte]0); $writer.Write([byte]0)
            $writer.Write([uint16]$entry.HotX); $writer.Write([uint16]$entry.HotY)
            $writer.Write([uint32]$entry.Png.Length); $writer.Write([uint32]$offset)
            $offset += $entry.Png.Length
        }
        foreach ($entry in $Entries) { $writer.Write($entry.Png) }
        $writer.Flush()
        return , $stream.ToArray()  # keep the byte[] intact; bare arrays get unrolled
    } finally { $writer.Dispose(); $stream.Dispose() }
}

# RIFF chunks are word aligned: an odd payload carries one pad byte that the
# enclosing chunk counts. Without this Windows refuses the whole .ani.
function New-AnimatedBytes {
    param([array]$Frames) # byte[] of complete CUR files
    $count = $Frames.Count
    $padded = @($Frames | ForEach-Object { $_.Length + ($_.Length % 2) })
    $rateBytes = 4 * $count
    $framesSize = 0
    for ($i = 0; $i -lt $count; $i++) { $framesSize += 8 + $padded[$i] }
    $listSize = 4 + $framesSize
    $riffSize = 4 + (8 + 36) + (8 + $rateBytes) + (8 + $listSize)

    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream)
    try {
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
        $writer.Write([uint32]$riffSize)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('ACON'))
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('anih'))
        $writer.Write([uint32]36)
        $writer.Write([uint32]36); $writer.Write([uint32]$count); $writer.Write([uint32]$count)
        $writer.Write([uint32]0); $writer.Write([uint32]0)
        $writer.Write([uint32]32); $writer.Write([uint32]1)
        $writer.Write([uint32]$AniRate); $writer.Write([uint32]1)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('rate'))
        $writer.Write([uint32]$rateBytes)
        for ($i = 0; $i -lt $count; $i++) { $writer.Write([uint32]$AniRate) }
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('LIST'))
        $writer.Write([uint32]$listSize)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('fram'))
        foreach ($frame in $Frames) {
            $writer.Write([System.Text.Encoding]::ASCII.GetBytes('icon'))
            $writer.Write([uint32]$frame.Length)
            $writer.Write($frame)
            if ($frame.Length % 2) { $writer.Write([byte]0) }
        }
        $writer.Flush()
        return , $stream.ToArray()  # keep the byte[] intact; bare arrays get unrolled
    } finally { $writer.Dispose(); $stream.Dispose() }
}

function Write-InstallInf {
    param([string]$Target, [string]$Theme, [hashtable]$Files)

    # $Files is keyed by cursor name; the INF talks in Windows role names, so
    # match on the file the cursor produced.
    $produced = @($Files.Values)
    $dir = '%10%\%CUR_DIR%\'

    $roleLines = @()
    foreach ($pair in ($SchemeOrder + $ExtraRoles)) {
        if ($produced -notcontains $pair[1]) { continue }
        $roleLines += 'HKCU,"Control Panel\Cursors",' + $pair[0] + ',0x00020000,"' + $dir + $pair[1] + '"'
    }

    $paths = @()
    foreach ($pair in $SchemeOrder) {
        if ($produced -contains $pair[1]) { $paths += $dir + $pair[1] }
    }

    $fileList = $produced | Sort-Object

    $lines = @(
        "; $Theme Cursors, generated by tools/build-windows.ps1"
        '; Artwork: apple_cursor v2.0.1 (GPL-3.0) https://github.com/ful1e5/apple_cursor'
        ''
        '[Version]'
        'signature="$CHICAGO$"'
        "$Theme Cursors"
        ''
        '[DefaultInstall]'
        'CopyFiles = Scheme.Cur'
        'AddReg    = Scheme.Reg,Wreg'
        ''
        '[DestinationDirs]'
        'Scheme.Cur = 10,"%CUR_DIR%"'
        ''
        '[Scheme.Reg]'
        ('HKCU,"Control Panel\Cursors\Schemes","%SCHEME_NAME%",,"' + ($paths -join ',') + '"')
        ''
        '[Wreg]'
    ) + $roleLines + @(
        'HKLM,"SOFTWARE\Microsoft\Windows\CurrentVersion\Runonce\Setup\","",,"rundll32.exe shell32.dll,Control_RunDLL main.cpl @0,1"'
        ''
        '[Scheme.Cur]'
    ) + $fileList + @(
        ''
        '[Strings]'
        'CUR_DIR             = "Cursors\' + $Theme + ' Cursors"'
        'SCHEME_NAME         = "' + $Theme + ' Cursors"'
    )

    Set-Content -LiteralPath (Join-Path $Target 'install.inf') -Value ($lines -join "`r`n") -Encoding UTF8

    $bat = @(
        '@echo off'
        'REM Remove the "' + $Theme + ' Cursors" scheme installed by install.inf.'
        'REG DELETE "HKCU\Control Panel\Cursors\Schemes" /v "' + $Theme + ' Cursors" /f'
        'echo Removed ' + $Theme + ' Cursors. Open Mouse Properties to pick another scheme.'
    )
    Set-Content -LiteralPath (Join-Path $Target 'uninstall.bat') -Value ($bat -join "`r`n") -Encoding ASCII
}

# ------------------------------------------------------------------------ main
$edge = Find-Edge
$schemes = Get-SchemeList
if ($Scheme) {
    $selected = @($schemes | Where-Object { $Scheme -contains $_.Name })
    $missing = @($Scheme | Where-Object { $_ -notin $schemes.Name })
    if ($missing) { throw "unknown scheme: $($missing -join ', ')" }
} else {
    $selected = $schemes
}
if (-not $selected) { throw 'no scheme selected' }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("apple-cursor-build-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$cache = Join-Path $work 'svg'
$figures = Join-Path $work 'png'
$profileDir = Join-Path $work 'edge-profile'
New-Item -ItemType Directory -Force -Path $cache, $figures, $profileDir | Out-Null

try {
    Write-Host "windows ${Profile} profile, scale $Scale"
    foreach ($current in $selected) {
        $theme = "AppleCursor-$($current.Name)"
        $target = Join-Path (Join-Path $Output $theme) ''
        $plan = Get-CursorPlan -ConfigPath $ProfileFile

        Write-Step "$($current.Name): planning $($plan.Cursors.Count) cursors"
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $target | Out-Null

        # Which (svg, size) pair is needed, and where it goes.
        $tilesBySize = @{}
        foreach ($cursor in $plan.Cursors) {
            foreach ($size in $cursor.Sizes) {
                if (-not $tilesBySize.ContainsKey($size)) { $tilesBySize[$size] = @{} }
                foreach ($frame in $cursor.Frames) {
                    $svg = Get-TintedSvg -Path $frame -Fill $current.Fill -Outline $current.Outline -CacheDir $cache
                    $key = "$svg|$size"
                    if ($tilesBySize[$size].ContainsKey($key)) { continue }
                    $stub = Get-ShortHash -Text $key -Length 16
                    $tilesBySize[$size][$key] = [pscustomobject]@{
                        Svg    = $svg
                        Target = Join-Path $figures "$stub-$size.png"
                        HotX   = $cursor.HotX
                        HotY   = $cursor.HotY
                    }
                }
            }
        }
        $images = 0
        foreach ($size in ($tilesBySize.Keys | Sort-Object)) {
            Invoke-SizeBatch -Edge $edge -Tiles $tilesBySize[$size] -Size $size -WorkDir $work `
                -ProfileDir $profileDir -Scale $Scale
            $images += $tilesBySize[$size].Count
        }
        Write-Step "rendered $images images in $($tilesBySize.Count) pages"

        $files = @{}
        foreach ($cursor in $plan.Cursors) {
            $entries = @()
            $frameBytes = @()
            foreach ($frame in $cursor.Frames) {
                $svg = Get-TintedSvg -Path $frame -Fill $current.Fill -Outline $current.Outline -CacheDir $cache
                foreach ($size in $cursor.Sizes) {
                    $key = "$svg|$size"
                    $png = [System.IO.File]::ReadAllBytes($tilesBySize[$size][$key].Target)
                    $entry = [pscustomobject]@{
                        Size = $size
                        HotX = Get-WinHotspot -Hot $cursor.HotX -Size $size
                        HotY = Get-WinHotspot -Hot $cursor.HotY -Size $size
                        Png  = $png
                    }
                    if ($cursor.Animated) { $frameBytes += , (New-CursorBytes -Entries @($entry)) } else { $entries += $entry }
                }
            }
            if ($cursor.Animated) {
                [System.IO.File]::WriteAllBytes((Join-Path $target "$($cursor.Role).ani"), (New-AnimatedBytes -Frames $frameBytes))
            } else {
                [System.IO.File]::WriteAllBytes((Join-Path $target "$($cursor.Role).cur"), (New-CursorBytes -Entries $entries))
            }
            $files[$cursor.Role] = if ($cursor.Animated) { "$($cursor.Role).ani" } else { "$($cursor.Role).cur" }
        }

        Write-InstallInf -Target $target -Theme $theme -Files $files
        # Recorded so install.ps1 can report the scale it actually got, instead of
        # the one it was asked for.
        [ordered]@{
            scheme  = $current.Name
            profile = $Profile
            scale   = $Scale
            sizes   = @($plan.Sizes)
            cursors = $files.Count
            builtAt = (Get-Date).ToString('o')
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $target 'build.json') -Encoding UTF8
        Write-Step "windows $target ($($files.Count) cursors)"
    }
    Write-Host "done: $($selected.Count) scheme(s) in $Output"
} finally {
    if ($KeepWork) {
        Write-Host "work directory kept: $work"
    } else {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
