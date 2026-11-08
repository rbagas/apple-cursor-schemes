"""Write Xcursor theme files from rendered frames.

An Xcursor file is a table of contents plus image records. Images carry a nominal
size, a hotspot in pixels and the delay until the next frame, so an animated
cursor is simply several records with the same nominal size. Pixels are 32-bit
ARGB in *premultiplied* form, which is what cairo hands us.
"""
import struct

MAGIC = 0x72756358
VERSION = 0x10000
IMAGE = 0xFFFD0002
COMMENT = 0xFFFE0001


def comment(text):
    payload = text.encode()
    return struct.pack('<3I', 12 + len(payload), COMMENT, len(payload)) + payload


def image(size, width, height, xhot, yhot, delay, argb):
    """One image record; argb is a sequence of premultiplied 32-bit values."""
    if len(argb) != width * height:
        raise ValueError(f'expected {width * height} pixels, got {len(argb)}')
    header = struct.pack('<4I5I', 36, IMAGE, size, 1, width, height, xhot, yhot, delay)
    return header + struct.pack('<%dI' % len(argb), *argb)


def write(path, blocks):
    """blocks: iterable of (kind, subtype, payload). TOC positions are computed here."""
    blocks = list(blocks)
    out = bytearray(struct.pack('<4I', MAGIC, 16, VERSION, len(blocks)))
    table = len(out)
    out += b'\0' * (12 * len(blocks))
    placed = []
    for kind, subtype, payload in blocks:
        placed.append((kind, subtype, len(out)))
        out += payload
    for index, (kind, subtype, position) in enumerate(placed):
        struct.pack_into('<3I', out, table + index * 12, kind, subtype, position)
    with open(path, 'wb') as handle:
        handle.write(out)
    return len(out)
