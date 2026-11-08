#!/usr/bin/env python3
"""Render a contact sheet of the built schemes, one row per theme."""
import argparse
import struct
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SHOWN = ('left_ptr', 'hand2', 'xterm', 'fleur')
BACKGROUNDS = [((30, 30, 46), 'dark'), ((255, 255, 255), 'light')]


def images(path):
    data = path.read_bytes()
    magic, header, _, count = struct.unpack_from('<4I', data, 0)
    if magic != 0x72756358:
        raise ValueError(f'{path}: not an Xcursor file')
    found = {}
    for index in range(count):
        kind, subtype, position = struct.unpack_from('<3I', data, header + index * 12)
        if kind != 0xFFFD0002:
            continue
        size, width, height = struct.unpack_from('<3I', data, position + 12)
        header_size = struct.unpack_from('<I', data, position)[0]
        pixels = struct.unpack_from('<%dI' % (width * height), data, position + header_size)
        found[subtype] = (width, height, pixels)
    return found


def frame(path, nominal):
    frames = images(path)
    size = min(frames, key=lambda value: abs(value - nominal))
    width, height, pixels = frames[size]
    surface = Image.new('RGBA', (width, height))
    surface.putdata([((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF, p >> 24) for p in pixels])
    return surface


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dist', type=Path, default=ROOT / 'dist/linux')
    parser.add_argument('--size', type=int, default=96, help='nominal size to render')
    parser.add_argument('--out', type=Path, default=ROOT / 'dist/preview.png')
    args = parser.parse_args()

    themes = sorted(path for path in args.dist.iterdir() if (path / 'cursors').is_dir())
    if not themes:
        raise SystemExit('no built themes; run tools/build_schemes.py first')
    cell = args.size + 24
    left = 210
    width = left + cell * len(SHOWN) * len(BACKGROUNDS)
    sheet = Image.new('RGB', (width, 26 + cell * len(themes)), (250, 250, 250))
    draw = ImageDraw.Draw(sheet)
    for index, name in enumerate(SHOWN):
        for slot, (_, label) in enumerate(BACKGROUNDS):
            draw.text((left + (index * len(BACKGROUNDS) + slot) * cell + 8, 8),
                      f'{name} {label}', fill=(40, 40, 40))
    for row, theme in enumerate(themes):
        top = 26 + row * cell
        draw.text((10, top + cell // 2 - 6), theme.name, fill=(40, 40, 40))
        for index, name in enumerate(SHOWN):
            path = theme / 'cursors' / name
            if not path.is_file():
                continue
            art = frame(path, args.size)
            for slot, (background, _) in enumerate(BACKGROUNDS):
                tile = Image.new('RGBA', (cell, cell), background + (255,))
                tile.alpha_composite(art, ((cell - art.width) // 2, (cell - art.height) // 2))
                sheet.paste(tile.convert('RGB'),
                            (left + (index * len(BACKGROUNDS) + slot) * cell, top))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(args.out)
    print(f'wrote {args.out} ({len(themes)} themes, {args.size} px)')


if __name__ == '__main__':
    main()
