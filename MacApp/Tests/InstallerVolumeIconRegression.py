"""Native macOS integration tests; create private scratch images, never open Finder.

Run explicitly with Xcode tools available:
    python3 Tests/InstallerVolumeIconRegression.py
No signing, notarization, installed-app changes, or user volume changes occur.
"""
import hashlib
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FINDER_INFO = 'com.apple.FinderInfo'


@unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS HFS+ and AppKit')
class InstallerVolumeIconTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools_directory = tempfile.TemporaryDirectory(prefix='echo-volume-icon-tools-')
        cls.addClassCleanup(cls.tools_directory.cleanup)
        cls.tools = Path(cls.tools_directory.name)
        cls.helper = cls.tools / 'volume-icon'
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Werror', '-framework', 'AppKit',
                        '-framework', 'CoreServices', str(ROOT / 'scripts/installer/InstallerVolumeIcon.m'),
                        '-o', str(cls.helper)], check=True, capture_output=True)
        iconset = cls.tools / 'Echo.iconset'
        iconset.mkdir()
        for source in (ROOT / 'Voicelab/Assets.xcassets/AppIcon.appiconset').glob('*.png'):
            shutil.copyfile(source, iconset / source.name)
        cls.icon = cls.tools / 'Echo.icns'
        subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(cls.icon)],
                       check=True, capture_output=True)

    def setUp(self):
        self.stage = Path(tempfile.mkdtemp(prefix='echo-volume-icon-test-'))
        self.mounted = None
        self.addCleanup(self.cleanup_image)
        self.content = self.stage / 'content'
        resources = self.content / 'Echo.app/Contents/Resources'
        resources.mkdir(parents=True)
        shutil.copyfile(self.icon, resources / 'AppIcon.icns')
        (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIconFile': 'AppIcon'}))
        self.writable = self.stage / 'writable.dmg'
        self.run_tool('hdiutil', 'create', '-quiet', '-fs', 'HFS+', '-volname', 'Echo icon test',
                      '-format', 'UDRW', '-srcfolder', str(self.content), str(self.writable))
        self.mount(self.writable, self.stage / 'first-mount')

    def cleanup_image(self):
        if self.mounted is not None:
            result = subprocess.run(['hdiutil', 'detach', '-quiet', str(self.mounted)], capture_output=True)
            if result.returncode != 0:
                raise RuntimeError(f'Could not detach {self.mounted}; scratch directory retained')
        shutil.rmtree(self.stage)

    def run_tool(self, *arguments):
        result = subprocess.run(arguments, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def mount(self, image, destination, readonly=False):
        destination.mkdir()
        self.run_tool('hdiutil', 'attach', '-quiet', '-nobrowse', '-noautoopen',
                      *(['-readonly'] if readonly else []), '-mountpoint', str(destination), str(image))
        self.mounted = destination

    def helper_result(self, mode):
        return subprocess.run([str(self.helper), mode, str(self.mounted)], text=True, capture_output=True)

    def assert_helper_succeeds(self, mode):
        result = self.helper_result(mode)
        self.assertEqual(result.returncode, 0, result.stderr)

    def finder_info(self):
        return bytes.fromhex(self.run_tool('/usr/bin/xattr', '-px', FINDER_INFO, str(self.mounted)).stdout)

    def set_finder_info(self, value):
        self.run_tool('/usr/bin/xattr', '-wx', FINDER_INFO, value.hex(), str(self.mounted))

    def app_files(self):
        return {str(path.relative_to(self.mounted)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (self.mounted / 'Echo.app').rglob('*') if path.is_file()}

    def test_exact_icon_and_unrelated_finder_flags_survive_conversion_and_remount(self):
        initial = bytearray(32)
        struct.pack_into('>H', initial, 8, 0x0006)  # Existing Finder label flags.
        self.set_finder_info(initial)
        original_app = self.app_files()
        self.assert_helper_succeeds('apply')
        self.assert_helper_succeeds('verify')
        expected = bytearray(initial)
        struct.pack_into('>H', expected, 8, 0x0406)
        self.assertEqual(self.finder_info(), expected)
        self.assertEqual(self.app_files(), original_app)
        self.run_tool('hdiutil', 'detach', '-quiet', str(self.mounted))
        self.mounted = None
        final = self.stage / 'installer.dmg'
        self.run_tool('hdiutil', 'convert', str(self.writable), '-quiet', '-format', 'ULFO', '-o', str(final))
        self.mount(final, self.stage / 'different-mount', readonly=True)
        self.assert_helper_succeeds('verify')
        self.assertEqual(self.finder_info(), expected)
        self.assertEqual((self.mounted / '.VolumeIcon.icns').read_bytes(), self.icon.read_bytes())
        self.assertEqual(self.app_files(), original_app)

    def test_missing_or_unsafe_declared_icon_fails_without_writing_volume(self):
        info = self.mounted / 'Echo.app/Contents/Info.plist'
        for value in (None, '../AppIcon', '/tmp/AppIcon', 'Missing', 'AppIcon.png'):
            with self.subTest(value=value):
                info.write_bytes(plistlib.dumps({} if value is None else {'CFBundleIconFile': value}))
                self.assertNotEqual(self.helper_result('apply').returncode, 0)
                self.assertFalse((self.mounted / '.VolumeIcon.icns').exists())

    def test_verifier_detects_lost_icon_bytes_and_flag(self):
        self.assert_helper_succeeds('apply')
        destination = self.mounted / '.VolumeIcon.icns'
        destination.write_bytes(b'corrupt icon')
        self.assertNotEqual(self.helper_result('verify').returncode, 0)
        destination.write_bytes(self.icon.read_bytes())
        self.set_finder_info(bytes(32))
        self.assertNotEqual(self.helper_result('verify').returncode, 0)

    def test_refuses_nonvolume_and_destination_symlink(self):
        result = subprocess.run([str(self.helper), 'apply', str(self.content)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.content / '.VolumeIcon.icns').exists())
        sentinel = self.stage / 'unrelated.icns'
        sentinel.write_bytes(b'keep unchanged')
        (self.mounted / '.VolumeIcon.icns').symlink_to(sentinel)
        self.assertNotEqual(self.helper_result('apply').returncode, 0)
        self.assertEqual(sentinel.read_bytes(), b'keep unchanged')


if __name__ == '__main__':
    unittest.main(verbosity=2)
