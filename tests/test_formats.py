"""Check the hand-written XCursor and Windows cursor containers."""
import struct
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))

import wincursor
import xcursor

try:
    import build_schemes
except SystemExit:  # pycairo or librsvg missing
    build_schemes = None

NEEDS_RENDERER = unittest.skipIf(build_schemes is None, 'pycairo/librsvg not installed')


def toc(data):
    magic, header, _, count = struct.unpack_from('<4I', data, 0)
    assert magic == xcursor.MAGIC
    return [(kind, subtype, position)
            for kind, subtype, position in (struct.unpack_from('<3I', data, header + i * 12)
                                            for i in range(count))]


class XCursorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cursor-test-')
        self.addCleanup(self.tmp.cleanup)

    def write(self, blocks):
        path = Path(self.tmp.name) / 'cursor'
        xcursor.write(path, blocks)
        return path.read_bytes()

    def test_comment_and_images_round_trip(self):
        pixels = [0xFF112233] * 16
        data = self.write([(xcursor.COMMENT, 1, xcursor.comment('test')),
                           (xcursor.IMAGE, 24, xcursor.image(24, 4, 4, 1, 2, 20, pixels))])
        entries = toc(data)
        self.assertEqual([(kind, subtype) for kind, subtype, _ in entries],
                         [(xcursor.COMMENT, 1), (xcursor.IMAGE, 24)])
        position = entries[1][2]
        size, = struct.unpack_from('<I', data, position + 8)
        width, height = struct.unpack_from('<2I', data, position + 16)
        header_size = struct.unpack_from('<I', data, position)[0]
        xhot, yhot, delay = struct.unpack_from('<3I', data, position + 24)
        self.assertEqual((size, width, height, xhot, yhot, delay), (24, 4, 4, 1, 2, 20))
        self.assertEqual(struct.unpack_from('<%dI' % 16, data, position + header_size)[0], 0xFF112233)

    def test_image_rejects_wrong_pixel_count(self):
        with self.assertRaises(ValueError):
            xcursor.image(16, 4, 4, 0, 0, 20, [0] * 15)


class WindowsCursorTests(unittest.TestCase):
    def test_cur_header_and_entries(self):
        frames = [(22, b'\x89PNG-one', (10, 10)), (64, b'\x89PNG-two', (31, 31))]
        data = wincursor.cur(frames)
        reserved, kind, count = struct.unpack_from('<HHH', data, 0)
        self.assertEqual((reserved, kind, count), (0, 2, 2))
        for index, (size, png, hotspot) in enumerate(frames):
            width, height, colors, res, xhot, yhot, length, offset = struct.unpack_from(
                '<BBBBHHII', data, 6 + 16 * index)
            self.assertEqual((width, height, colors, res), (size, size, 0, 0))
            self.assertEqual((xhot, yhot), hotspot)
            self.assertEqual(data[offset:offset + length], png)

    def test_ani_structure(self):
        frames = [wincursor.cur([(32, b'\x89PNG-frame%d' % index, (5, 5))]) for index in range(3)]
        data = wincursor.ani(frames, rate=2)
        self.assertEqual(data[:4], b'RIFF')
        self.assertEqual(data[8:12], b'ACON')
        self.assertEqual(struct.unpack_from('<I', data, 4)[0], len(data) - 8)
        anih = struct.unpack_from('<9I', data, data.find(b'anih') + 8)
        self.assertEqual(anih, (36, 3, 3, 0, 0, 32, 1, 2, wincursor.AF_ICON))
        self.assertEqual(data.count(b'icon'), 3)
        window = data.find(b'rate')
        self.assertEqual(struct.unpack_from('<I', data, window)[0] if False else
                         struct.unpack_from('<I', data, window + 4)[0], 12)
        self.assertEqual(struct.unpack_from('<3I', data, window + 8), (2, 2, 2))

    def test_empty_frames_rejected(self):
        for writer in (wincursor.cur, wincursor.ani):
            with self.assertRaises(ValueError):
                writer([])


@NEEDS_RENDERER
class HotspotTests(unittest.TestCase):
    def test_x11_and_windows_formulas_match_upstream(self):
        spec = {'x_hotspot': 80, 'y_hotspot': 38}
        self.assertEqual(build_schemes.x_hotspot(spec, 32, 'x11'), [10, 4])
        self.assertEqual(build_schemes.x_hotspot(spec, 16, 'x11'), [5, 2])
        self.assertEqual(build_schemes.x_hotspot(spec, 96, 'x11'), [30, 14])
        centre = {'x_hotspot': 128, 'y_hotspot': 128}
        self.assertEqual(build_schemes.x_hotspot(centre, 64, 'windows'), [31, 31])
        self.assertEqual(build_schemes.x_hotspot(centre, 171, 'windows'), [85, 85])

    def test_x11_sizes_and_symlink_count_match_upstream_config(self):
        config = build_schemes.load_toml(build_schemes.DEFAULT_CONFIG)
        specs = build_schemes.cursor_specs(config)
        self.assertEqual(len(specs), 44)
        self.assertEqual(sum(len(spec['symlinks']) for spec in specs), 101)
        sizes = config['cursors']['fallback_settings']['x11_sizes']
        self.assertEqual(sizes, [16, 20, 22, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96])
        animated = [spec for spec in specs if len(spec['frames']) > 1]
        self.assertEqual(sorted(spec['name'] for spec in animated), ['left_ptr_watch', 'wait'])
        self.assertTrue(all(len(spec['frames']) == 40 for spec in animated))


if __name__ == '__main__':
    unittest.main(verbosity=2)
