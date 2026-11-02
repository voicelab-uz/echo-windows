#!/usr/bin/env python3
"""Write the installer's small, fixed Finder layout without Finder automation.

The Buddy allocator and DSDB record format are documented by ds_store:
https://ds-store.readthedocs.io/en/latest/
This writer intentionally supports one 4096-byte leaf, not editing arbitrary
Finder stores. Alias bytes come from macOS on the mounted image, so the
background survives conversion, renaming the DMG, and a different mount path.
"""
import argparse
from pathlib import Path
import plistlib
import struct


def record(name, key, kind, value):
    encoded_name = name.encode('utf-16be')
    data = struct.pack('>I', len(encoded_name) // 2) + encoded_name + key + kind
    if kind == b'blob':
        return data + struct.pack('>I', len(value)) + value
    if kind == b'long':
        return data + struct.pack('>I', value)
    if kind == b'type' and len(value) == 4:
        return data + value
    raise ValueError('Unsupported Finder record type')


def store_bytes(entries):
    """A valid Buddy heap with a DSDB superblock and one sorted leaf."""
    leaf = struct.pack('>II', 0, len(entries)) + b''.join(
        record(*entry) for entry in sorted(entries, key=lambda entry: (entry[0].lower(), entry[1])))
    if len(leaf) > 4096:
        raise ValueError('Installer layout exceeds its single page')
    # Allocated regions: header [0,32), DSDB [32,64), allocator [2048,4096),
    # leaf [4096,8192). All allocator offsets exclude the first four bytes.
    allocator = struct.pack('>II', 3, 0)
    allocator += struct.pack('>256I', 2048 | 11, 32 | 5, 4096 | 12, *([0] * 253))
    allocator += struct.pack('>I', 1) + b'\x04DSDB' + struct.pack('>I', 1)
    for power in range(32):
        free = (1 << power) if 6 <= power <= 10 or 13 <= power <= 30 else None
        allocator += struct.pack('>I', int(free is not None))
        if free is not None:
            allocator += struct.pack('>I', free)
    content = bytearray(8196)
    content[:36] = struct.pack('>I4sIII16s', 1, b'Bud1', 2048, 2048, 2048, bytes(16))
    # DSDB counts internal levels, not leaf levels: a single leaf has depth 0.
    content[36:56] = struct.pack('>IIIII', 2, 0, len(entries), 1, 4096)
    content[2052:2052 + len(allocator)] = allocator
    content[4100:4100 + len(leaf)] = leaf
    return bytes(content)


def portable_alias(alias):
    """Retain native file/volume identity, remove every host-specific path.

    Carbon Alias v2 tags are documented by mac_alias. macOS adds a recursive
    alias to the scratch DMG (tag 20); shipping it makes Finder try to reopen a
    deleted developer path. Our image-relative path is sufficient after mount.
    """
    if len(alias) < 154 or struct.unpack_from('>HH', alias, 4) != (len(alias), 2):
        raise ValueError('Background alias is incomplete or not version 2')
    result = bytearray(alias[:150])
    position = 150
    ended = False
    while position + 4 <= len(alias):
        tag, size = struct.unpack_from('>hh', alias, position)
        position += 4
        if size < 0 or position + size > len(alias):
            raise ValueError('Background alias tag is incomplete')
        value = alias[position:position + size]
        position += size + (size % 2)
        if tag == -1:
            ended = size == 0 and position == len(alias)
            break
        if tag not in (2, 19, 20, 21):
            result += struct.pack('>hh', tag, size) + value + bytes(size % 2)
    if not ended:
        raise ValueError('Background alias has no valid terminator')
    for tag, value in ((2, b'Echo:.background:background.tiff'), (19, b'/Volumes/Echo')):
        result += struct.pack('>hh', tag, len(value)) + value + bytes(len(value) % 2)
    result += struct.pack('>hh', -1, 0)
    struct.pack_into('>H', result, 4, len(result))
    return bytes(result)


def layout_bytes(alias):
    alias = portable_alias(alias)
    # Finder bounds include its 32-point titlebar; retain 420 points for artwork.
    window = {'WindowBounds': '{{200, 140}, {640, 452}}', 'ShowToolbar': False,
              'ShowSidebar': False, 'ContainerShowSidebar': False, 'ShowStatusBar': False,
              'ShowPathbar': False, 'ShowTabView': False, 'PreviewPaneVisibility': False,
              'SidebarWidth': 0}
    view = {'viewOptionsVersion': 1, 'backgroundType': 2, 'backgroundImageAlias': alias,
            'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
            'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'gridSpacing': 100.0,
            'arrangeBy': 'none', 'showIconPreview': True, 'showItemInfo': False,
            'labelOnBottom': True, 'textSize': 13.0, 'iconSize': 112.0}
    binary = lambda obj: plistlib.dumps(obj, fmt=plistlib.FMT_BINARY, sort_keys=True)
    return store_bytes([
        ('.', b'bwsp', b'blob', binary(window)),
        ('.', b'icvp', b'blob', binary(view)),
        ('.', b'icvl', b'type', b'icnv'),
        ('.', b'vSrn', b'long', 1),
        ('Applications', b'Iloc', b'blob', struct.pack('>IIII', 465, 180, 0xFFFFFFFF, 0xFFFF0000)),
        ('Echo.app', b'Iloc', b'blob', struct.pack('>IIII', 175, 180, 0xFFFFFFFF, 0xFFFF0000)),
    ])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mount', type=Path)
    parser.add_argument('alias', type=Path)
    args = parser.parse_args()
    if not (args.mount / 'Echo.app').is_dir() or (args.mount / 'Applications').readlink() != Path('/Applications'):
        parser.error('Expected Echo.app and the Applications shortcut on the installer')
    if not (args.mount / '.background/background.tiff').is_file():
        parser.error('Installer background is missing')
    alias = portable_alias(args.alias.read_bytes())
    args.alias.write_bytes(alias)
    (args.mount / '.DS_Store').write_bytes(layout_bytes(alias))


if __name__ == '__main__':
    main()
