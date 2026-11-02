"""Decode the installer layout independently and verify the shipped contract."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('installer_layout', ROOT / 'scripts/installer/layout.py')
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)


def read_store(data):
    magic, signature, root, size, duplicate = struct.unpack_from('>I4sIII', data)
    assert (magic, signature, root) == (1, b'Bud1', duplicate)
    count = struct.unpack_from('>I', data, root + 4)[0]
    addresses = struct.unpack_from(f'>{count}I', data, root + 12)
    toc = root + 4 + 8 + ((count + 255) // 256) * 1024
    assert struct.unpack_from('>I', data, toc)[0] == 1
    assert data[toc + 4:toc + 9] == b'\x04DSDB'
    block_id = struct.unpack_from('>I', data, toc + 9)[0]
    superblock = (addresses[block_id] & ~31) + 4
    leaf, levels, records, nodes, page_size = struct.unpack_from('>IIIII', data, superblock)
    # Independent format oracle: DSDB counts internal levels (leaf-only = 0).
    assert (levels, nodes, page_size) == (0, 1, 4096)
    position = (addresses[leaf] & ~31) + 4
    next_node, leaf_records = struct.unpack_from('>II', data, position)
    assert next_node == 0 and leaf_records == records
    position += 8
    result = {}
    for _ in range(records):
        name_size = struct.unpack_from('>I', data, position)[0] * 2
        position += 4
        name = data[position:position + name_size].decode('utf-16be')
        position += name_size
        key, kind = struct.unpack_from('>4s4s', data, position)
        position += 8
        if kind == b'blob':
            value_size = struct.unpack_from('>I', data, position)[0]
            position += 4
            value = data[position:position + value_size]
            position += value_size
        else:
            value = data[position:position + 4]
            position += 4
        result[name, key] = (kind, value)
    return result


class InstallerLayoutTests(unittest.TestCase):
    def alias(self):
        return bytes(4) + struct.pack('>HH', 154, 2) + bytes(142) + struct.pack('>hh', -1, 0)

    def test_finder_opens_a_compact_uncluttered_icon_view(self):
        records = read_store(layout.layout_bytes(self.alias()))
        window = plistlib.loads(records['.', b'bwsp'][1])
        view = plistlib.loads(records['.', b'icvp'][1])
        self.assertEqual(window['WindowBounds'], '{{200, 140}, {640, 452}}')
        self.assertFalse(any(window[key] for key in ('ShowToolbar', 'ShowSidebar', 'ShowPathbar', 'ShowStatusBar')))
        self.assertEqual(records['.', b'icvl'], (b'type', b'icnv'))
        self.assertEqual(view['backgroundImageAlias'], layout.portable_alias(self.alias()))
        self.assertEqual(view['backgroundType'], 2)
        self.assertEqual(view['iconSize'], 112.0)
        self.assertEqual(view['arrangeBy'], 'none')
        self.assertTrue(view['labelOnBottom'])
        self.assertEqual(struct.unpack('>IIII', records['Echo.app', b'Iloc'][1])[:2], (175, 180))
        self.assertEqual(struct.unpack('>IIII', records['Applications', b'Iloc'][1])[:2], (465, 180))

    def test_background_alias_contains_no_build_host_paths(self):
        alias = bytearray(self.alias()[:-4])
        for tag, value in ((2, b'/private/tmp/private/path'), (19, b'/private/tmp/mount'), (20, b'scratch.dmg'), (21, b'private')):
            alias += struct.pack('>hh', tag, len(value)) + value + bytes(len(value) % 2)
        alias += struct.pack('>hh', -1, 0)
        struct.pack_into('>H', alias, 4, len(alias))
        portable = layout.portable_alias(bytes(alias))
        self.assertNotIn(b'/private', portable)
        self.assertNotIn(b'scratch.dmg', portable)
        self.assertIn(b'Echo:.background:background.tiff', portable)
        self.assertIn(b'/Volumes/Echo', portable)
        self.assertEqual(layout.portable_alias(portable), portable)

    def test_leaf_only_tree_has_no_internal_levels(self):
        data = bytearray(layout.layout_bytes(self.alias()))
        allocator_offset = struct.unpack_from('>I', data, 8)[0]
        dsdb_address = struct.unpack_from('>I', data, allocator_offset + 16)[0]
        dsdb_offset = (dsdb_address & ~31) + 4
        self.assertEqual(struct.unpack_from('>IIIII', data, dsdb_offset), (2, 0, 6, 1, 4096))
        # This exact malformed header made real Finder discard the entire
        # layout and fall back to its default 920-point window/grid positions.
        struct.pack_into('>I', data, dsdb_offset + 4, 1)
        with self.assertRaises(AssertionError):
            read_store(bytes(data))

    def test_output_is_deterministic_for_same_volume_alias(self):
        self.assertEqual(layout.layout_bytes(self.alias()), layout.layout_bytes(self.alias()))

    def test_invalid_alias_cannot_publish_a_broken_background(self):
        for value in (b'', b'partial', self.alias()[:-1], bytes(200)):
            with self.subTest(value=len(value)), self.assertRaises(ValueError):
                layout.layout_bytes(value)

    def test_oversized_store_is_rejected_instead_of_silent_corruption(self):
        with self.assertRaisesRegex(ValueError, 'single page'):
            layout.store_bytes([('.', b'test', b'blob', bytes(4096))])


if __name__ == '__main__':
    unittest.main()
