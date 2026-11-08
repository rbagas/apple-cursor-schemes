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

Building needs Python with cairo and librsvg bindings:

```bash
# Ubuntu / Debian
sudo apt install python3 python3-cairo python3-gi gir1.2-rsvg-2.0

# Fedora
sudo dnf install python3 python3-cairo python3-gobject librsvg2

# Arch
sudo pacman -S python python-cairo python-gobject librsvg
```

Installing prebuilt themes needs none of that — they are plain directories.

## Build

```bash
python3 tools/build_schemes.py --list          # show the schemes
python3 tools/build_schemes.py                 # build all, both platforms
python3 tools/build_schemes.py --scheme Nord   # build one scheme
python3 tools/build_schemes.py --platforms linux
python3 tools/preview.py --out dist/preview.png
```

Output lands in `dist/linux/<theme>/` (XCursor) and `dist/windows/<theme>/`
(`.cur`, `.ani`, `install.inf`). A full build takes about 20 seconds and writes
nothing outside `dist/`.

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

Add an entry to `schemes.toml` and rebuild:

```toml
[[scheme]]
name = 'Solarized-Dark'
comment = 'Solarized base02 fill'
fill = '#073642'
outline = '#93a1a1'
```

`fill` replaces `#00FF00` in the SVGs (the pointer body) and `outline` replaces
`#0000FF` (the edge). The drop shadow is part of the artwork and stays put.

## How it works

- `svg/` holds the upstream 256×256 sources; `configs/x.build.toml` and
  `configs/win_*.build.toml` hold upstream's sizes, per-cursor hotspots, symlink
  aliases and Windows role names. Both are used as-is.
- `tools/build_schemes.py` renders each SVG to every target size with librsvg
  (instead of cbmp's single bitmap plus resize), writes XCursor files with
  `tools/xcursor.py`, and writes Windows cursors with `tools/wincursor.py`.
- Hotspots follow upstream exactly: `floor(hot × size / 256)` for XCursor and
  `(hot × size − 1) // 256` for Windows. Both are verified against the upstream
  release; hotspot positions match at all 14 sizes.
- Pixels are stored premultiplied for XCursor, PNG-compressed for Windows, and
  animated frames use the Windows tick rate rather than the XCursor millisecond
  delay.

## Credits and licence

Cursor artwork: [apple_cursor](https://github.com/ful1e5/apple_cursor) by
Abdulkaiz Khatri (ful1e5) and contributors, GPL-3.0. See `LICENSE`.
This fork only changes colours and the build/install tooling, so the result stays
GPL-3.0. The original `svg/`, `configs/` and the upstream README remain in the
tree; upstream's release notes are in `CHANGELOG.md`.
