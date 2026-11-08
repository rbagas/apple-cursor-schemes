"""Write Windows .cur and .ani cursor files.

The layout mirrors what the upstream release ships: PNG-compressed images inside
a CUR container (Vista and newer read those natively), and animated cursors as a
RIFF/ACON file whose frames are complete .cur blobs. Animated frames use the
Windows tick rate (1 jiffy = 1/60 s), not the XCursor millisecond delay.
"""
import struct

RIFF = b'RIFF'
ACON = b'ACON'
AF_ICON = 1
ICON_TYPE = 2


def cur(frames):
    """frames: sequence of (size, png_bytes, (hotspot_x, hotspot_y)) -> CUR bytes."""
    if not frames:
        raise ValueError('a cursor needs at least one frame')
    entries, payload = [], b''
    offset = 6 + 16 * len(frames)
    for size, png, (hot_x, hot_y) in frames:
        if not 1 <= size <= 256:
            raise ValueError(f'cursor size {size} does not fit a CUR entry')
        entries.append(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0,
                                   hot_x, hot_y, len(png), offset + len(payload)))
        payload += png
    header = struct.pack('<HHH', 0, ICON_TYPE, len(frames))
    return header + b''.join(entries) + payload


def _chunk(tag, data):
    return tag + struct.pack('<I', len(data)) + data


def ani(cursors, rate=1):
    """cursors: sequence of complete CUR files -> animated cursor bytes."""
    if not cursors:
        raise ValueError('an animated cursor needs at least one frame')
    count = len(cursors)
    # anih: cbSize, nFrames, nSteps, width, height, bitcount, planes, disp rate, flags
    header = struct.pack('<9I', 36, count, count, 0, 0, 32, 1, rate, AF_ICON)
    rates = struct.pack('<%dI' % count, *([rate] * count))
    frames = b''.join(_chunk(b'icon', data) for data in cursors)
    body = ACON + _chunk(b'anih', header) + _chunk(b'rate', rates) + _chunk(b'LIST', b'fram' + frames)
    return RIFF + struct.pack('<I', len(body)) + body


def write(path, data):
    with open(path, 'wb') as handle:
        handle.write(data)
    return len(data)
