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

## Build

```bash
./build.sh                          # all schemes, both platforms
./build.sh --list                   # show the schemes
./build.sh --scheme Nord            # one scheme
./build.sh --platforms linux        # one platform
./build.sh --jobs 4                 # cap parallel renders (default: CPU count)
./preview.sh                        # contact sheet in dist/preview.png
```

Output lands in `dist/linux/<theme>/` (XCursor) and `dist/windows/<theme>/`
(`.cur`, `.ani`, `install.inf`). All seven schemes build in about a minute
(56 s measured on a 16-thread machine, 8 s per scheme); `--jobs` controls how
many renders run at once. Nothing is written outside `dist/` except a temporary
directory that is removed on exit.

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

1. Extract `dist/windows/<theme>/` (or the release zip for that scheme).
2. Right-click `install.inf` → **Install**. Accept the elevation prompt if asked.
3. **Settings → Bluetooth & devices → Mouse → Additional mouse options →
   Pointers**, choose the `AppleCursor-… Cursors` scheme, then **Apply**.

The scheme is registered per user under `Control Panel\Cursors` and the files
live in `%SystemRoot%\Cursors\<theme> Cursors`. `install.inf` also queues the
Mouse Properties dialog to open once, so step 3 is usually already on screen.

To remove it, run `uninstall.bat` and pick another scheme in Mouse Properties.
If SmartScreen or your policy blocks `.inf` installs, copy the folder into
`%SystemRoot%\Cursors\` yourself and select each `.cur`/`.ani` by hand in the
same dialog.

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
- Pixels are stored premultiplied for XCursor and PNG-compressed for Windows.

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
