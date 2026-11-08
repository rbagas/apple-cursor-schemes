# Apple Cursor Schemes

macOS-style cursors in seven colour schemes, for Linux desktops and Windows.

The artwork is [ful1e5/apple_cursor](https://github.com/ful1e5/apple_cursor) (GPL-3.0).
This repository is a fork: it recolours the original SVGs, builds the cursor
files without upstream's Node toolchain, and ships an installer.

| Scheme | Fill | Outline | Look |
| --- | --- | --- | --- |
| `macOS` | `#000000` | `#FFFFFF` | upstream, black pointer with white edge |
| `macOS-White` | `#FFFFFF` | `#000000` | upstream inverted variant |
| `GitHub-Dark` | `#24292f` | `#FFFFFF` | GitHub Dark v1 graphite |
| `Nord` | `#4c566a` | `#eceff4` | Nord Polar Night slate |
| `Dracula` | `#44475a` | `#f8f8f2` | Dracula current-line |
| `Catppuccin-Mocha` | `#cba6f7` | `#1e1e2e` | Catppuccin mauve |
| `Tokyo-Night` | `#1a1b26` | `#7aa2f7` | near-black fill, blue edge |

Every scheme is a full theme: 44 cursors, 101 aliases, 14 sizes (16–96 px),
animated busy and waiting cursors, and the Windows set of 21 pointer roles.

## Requirements

Building is plain shell and needs two command line tools:

```bash
# Ubuntu / Debian
sudo apt install librsvg2-bin xcursorgen

# Fedora
sudo dnf install librsvg2-tools xcursorgen

# Arch
sudo pacman -S librsvg xorg-xcursorgen
```

Installing prebuilt themes needs none of that — they are plain directories.

### Windows

Nothing above is needed on Windows. `tools/build-windows.ps1` is a PowerShell
port that rasterises through the Edge renderer that ships with Windows 10 and 11,
so it runs in a plain shell: no MSYS2, no WSL, no librsvg, no Node.

```powershell
.\tools\build-windows.ps1 -Scheme GitHub-Dark   # dist\windows\AppleCursor-GitHub-Dark
```

It renders one HTML page per cursor size (fixed tiles), screenshots the page once,
and slices the tiles back out at 4x supersampling — seven Edge runs for a full
regular profile, under ten seconds. `-Profile regular|large|extra-large`,
`-Scale` and `-Output` behave like the shell builder's options.

## Build

```bash
./build.sh                          # all schemes, both platforms
./build.sh --list                   # show the schemes
./build.sh --scheme Nord            # one scheme
./build.sh --platforms linux        # one platform
./build.sh --jobs 4                 # cap parallel renders (default: CPU count)
./build.sh --force                  # rebuild even if a theme is unchanged
./build.sh --clear-cache            # drop cached renders
./preview.sh                        # contact sheet in dist/preview.png
```

Output lands in `dist/linux/<theme>/` (XCursor) and `dist/windows/<theme>/`
(`.cur`, `.ani`, `install.inf`). `--jobs` controls how many renders run at once.
On Windows use `tools/build-windows.ps1` instead; it writes the same
`dist/windows/<theme>/` payload.

### Build cache

Rendered images are cached by content hash under
`${XDG_CACHE_HOME:-~/.cache}/apple-cursor-schemes`, and each built theme carries a
stamp of every input (palette, configs, scripts). Measured on a 16-thread
machine:

| Build | Time |
| --- | --- |
| Everything, no cache (7 schemes) | 57 s |
| Same after a colour change in one scheme | 8 s |
| Nothing changed | 0.05 s |

So iterating on the scripts or a single palette costs seconds, not a minute.
`--no-cache` ignores the cache, `--clear-cache` deletes it (about 40 MB), and
`--force` rebuilds a theme whose stamp still matches.

## Install on Linux

```bash
./install.sh                          # install AppleCursor-GitHub-Dark and apply it
./install.sh --scheme Nord            # a specific scheme (builds it if needed)
./install.sh --all                    # install all seven, keep the current theme
./install.sh --list                   # list the schemes
./install.sh --size 32                # also set the GNOME cursor size
./install.sh --system --all           # /usr/share/icons instead of ~/.local/share/icons
./install.sh --uninstall --scheme Nord
```

`install.sh` copies the theme into `${XDG_DATA_HOME:-~/.local/share}/icons`,
sets `cursor-theme` through gsettings when a GNOME session is reachable, and
writes `~/.config/environment.d/90-cursor.conf` so Xwayland, Qt and Electron
apps match. GTK and GNOME Shell switch immediately; other apps follow at the
next login. Desktops without gsettings can select the theme in their own cursor
settings — the directory is all they need.

On the three distributions above the installer is the same; only the build
dependencies differ, and those are only needed when `dist/` is empty.

Manual install, for any desktop:

```bash
cp -r dist/linux/AppleCursor-Nord ~/.local/share/icons/
```

For a cursor that lands exactly on a native asset instead of being rescaled:
the themes ship 16, 20, 22, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88 and 96 px.
At 1.25 fractional scaling a logical size of 26 asks for 32 px, which is shipped.

## Install on Windows

No admin, no reboot, and no MSYS2 or WSL: `install.ps1` builds the theme when it
is missing, copies it to `%LOCALAPPDATA%\Cursors\<theme>`, registers the scheme
under `HKCU\Control Panel\Cursors` and applies it with `SPI_SETCURSORS`, so the
pointers change before the command returns.

### Step by step, from a terminal

**1. Open a terminal.** Press `Win`+`X` and pick **Terminal** (or **Windows
PowerShell**). Every command below is run in that window.

**2. Get the repository.**

```powershell
git clone https://github.com/rbagas/apple-cursor-schemes.git
cd apple-cursor-schemes
```

No git on the machine? Install it, then repeat the commands above:

```powershell
winget install --id Git.Git -e --source winget
```

Or skip git and unpack the ZIP instead — the folder it creates is `apple-cursor-schemes-main`:

```powershell
Invoke-WebRequest https://github.com/rbagas/apple-cursor-schemes/archive/refs/heads/main.zip -OutFile cursors.zip
Expand-Archive cursors.zip -DestinationPath . -Force
cd apple-cursor-schemes-main
```

**3. Install a scheme.**

```powershell
.\install.ps1 -Scheme GitHub-Dark -Scale 0.7
```

If PowerShell answers *"running scripts is disabled on this system"*, run the same
script for this one command only, which needs no policy change:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Scheme GitHub-Dark -Scale 0.7
```

The first run builds the cursors with the Edge renderer (a few seconds, seven
screenshots), so the output looks like this:

```
building AppleCursor-GitHub-Dark...
windows regular profile, scale 0.7
  GitHub-Dark: planning 21 cursors
  rendered 194 images in 7 pages
  windows C:\...\dist\windows\AppleCursor-GitHub-Dark\ (21 cursors)
done: 1 scheme(s) in C:\...\dist\windows
installed: AppleCursor-GitHub-Dark Cursors
cursors  : C:\Users\<you>\AppData\Local\Cursors\AppleCursor-GitHub-Dark
scale    : 0.7
```

The pointers are already live when it prints `installed:`.

**4. Check that it took.** *Settings → Bluetooth & devices → Mouse → Additional
mouse options → Pointers*: the Scheme box should read
`AppleCursor-GitHub-Dark Cursors`. From the terminal:

```powershell
(Get-Item 'HKCU:\Control Panel\Cursors').GetValue('')
```

Which prints `AppleCursor-GitHub-Dark Cursors`. Note that the pointer over the
terminal is whatever the terminal sets for text selection, so move onto the
desktop to see the arrow.

**5. Change or undo.**

```powershell
.\install.ps1 -Scheme Nord -Scale 0.7   # any scheme from `Get-Content schemes.conf`
.\install.ps1 -Size 32                  # also set the Windows pointer size
.\install.ps1 -Restore                  # the pointers from before the first install
.\install.ps1 -Uninstall                # remove the scheme and its files
```

`-Restore` replays the settings saved in `previous-scheme.json` next to the
installed theme, so it works even after you have played with others.

### Choosing a size

Windows sizes cursors per slot and the artwork fills its canvas more than the
stock pointers do (21x29 px of arrow in a 32 px slot against 12x19). `-Scale 0.7`
shrinks the glyph inside its slot, keeping the hotspot, so it matches the
familiar size:

| slot | stock / macOS pointers | `-Scale 1` | `-Scale 0.7` |
| --- | --- | --- | --- |
| 32 px | 12x19 | 21x29 | ~15x21 |
| 64 px | 25x38 | 37x56 | 27x40 |

`-Scale` is baked in at build time, so pass it on a run that rebuilds: add
`-Build` (or delete `dist\windows\<theme>` first) when the theme already exists.
The installer reports the scale it actually installed, and warns when `-Scale`
was ignored because a theme was already sitting in `dist`.

### Machine-wide install with the .inf

`dist/windows/<theme>/install.inf` still exists for the classic route: right-click
→ **Install**, accept the elevation prompt, then pick the `AppleCursor-… Cursors`
scheme in **Settings → Bluetooth & devices → Mouse → Additional mouse options →
Pointers**. It copies the files into `%SystemRoot%\Cursors\<theme> Cursors` and
queues the Mouse Properties dialog so the scheme is one click away. `uninstall.bat`
in the same folder undoes it.

Each `.cur` carries six sizes (22, 32, 43, 64, 86, 171 px for the default
profile) with PNG-compressed images, and the animated cursors are RIFF `.ani`
files with one image per frame, so Windows scales them to your cursor size.

## Adding a scheme

Add a line to `schemes.conf` and rebuild:

```
Solarized-Dark|#073642|#93a1a1|Solarized base02 fill
```

`fill` replaces `#00FF00` in the SVGs (the pointer body) and `outline` replaces
`#0000FF` (the edge). The drop shadow is part of the artwork and stays put.

## How it works

- `svg/` holds the upstream 256×256 sources; `configs/x.build.toml` and
  `configs/win_*.build.toml` hold upstream's sizes, per-cursor hotspots, symlink
  aliases and Windows role names. Both are used as-is.
- `build.sh` is the whole builder: `rsvg-convert` renders each SVG straight to
  every target size (instead of cbmp's single bitmap plus resize), `xcursorgen`
  writes the XCursor files, and the Windows `.cur`/`.ani` containers are emitted
  with `printf` — headers, offsets and RIFF chunks are little-endian fields.
- Renders run in parallel (`lib/render.sh` fed through `xargs -P`), and the
  colour substitution happens once per SVG instead of once per image. XCursor
  and Windows share one render pass, deduplicated by output path, so a size both
  platforms need (22, 32, 64 px) is rasterised once.
- The upstream configs are read with `awk` (one section per cursor, flat keys),
  so the sizes, hotspots, aliases and Windows role names stay upstream's data.
- Hotspots: XCursor uses `floor(hot × size / 256)` and matches upstream at all 14
  sizes. Windows upstream is not consistent to the pixel; this build uses
  `(hot × size − 1) // 256`, which agrees with the release on 19 of 24 images and
  differs by at most 1 px elsewhere.
- Animated pointers ship 40 frames at 65 px — upstream's own `win_sizes = 65`
  override for those cursors — inside a RIFF `ACON` file at 2 jiffies per frame.
  RIFF pads odd chunks to a word boundary and Windows strictly requires it, so a
  frame whose payload is odd carries one pad byte.
- Pixels are stored premultiplied for XCursor and PNG-compressed for Windows.
- `tools/build-windows.ps1` is the same build for a plain Windows shell: it writes
  one HTML page per cursor size, screenshots it through the bundled Edge renderer,
  slices the tiles, and downsamples them 4x in .NET. `install.ps1` then installs a
  theme per user without elevation, which `.inf`-based installers cannot do.
- The 17 slots of a `Control Panel\Cursors\Schemes` value are positional, so the
  `.inf` writes them in the dialog's own order; roles Windows does not show
  (`Grab`, `Pan`) are set as values but stay out of the scheme string.

## Credits and licence

Cursor artwork: [apple_cursor](https://github.com/ful1e5/apple_cursor) by
Abdulkaiz Khatri (ful1e5) and contributors, licensed **GPL-3.0**. The full licence
text is in [`LICENSE`](LICENSE) and is unchanged from upstream.

This repository is a fork of that work and stays under **GPL-3.0**; the added
build and installer scripts are released under the same licence, so there is no
mixed-licence question. Both the original sources (`svg/`, `configs/`) and the
generated cursors come with the tree, so the corresponding source is always
available from the same place as any build.

### Changes from upstream

Modified in this fork (2026-11-08), as required by GPL-3.0 section 5(a):

- `README.md` rewritten around the scheme set, installers and both platforms.
- `schemes.conf`, `build.sh`, `preview.sh`, `install.sh` and `tests/run.sh` added.
- Windows without MSYS2/WSL: `tools/build-windows.ps1` (PowerShell + Edge) and
  `install.ps1` (per-user install, no elevation) added.
- Upstream's Node/cbmp/ctgen build files (`build.sh`, `package.json`,
  `yarn.lock`, `render.json`, `pling.txt`) and its CI workflow removed, because
  `build.sh` replaces them.
- `.gitignore` extended for the build output and Python caches.

**Not modified:** every file in `svg/` and `configs/`. Colours are substituted at
build time from the two placeholder colours upstream already uses, so the artwork
stays attributable byte-for-byte to its authors.

### Trademarks

The cursor shapes are an independent redraw created by the upstream project, not
Apple's artwork. "macOS" and "Apple" are used descriptively to name the style; this
project is not affiliated with, endorsed by, or sponsored by Apple Inc. macOS is a
trademark of Apple Inc. All other product names belong to their respective owners.
