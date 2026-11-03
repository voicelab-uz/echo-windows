# Echo's drag-to-install window

The release DMG opens a compact 640 × 452 Finder window: 32 points of titlebar
plus a 640 × 420 canvas. Two native 112-point icons sit on a clean warm-white
surface, linked by a dotted sound-wave arrow. Separate transparent peach-and-blue
Echo characters add a playful brand detail. The main instruction is **“Drag Echo
to Applications”**, set in bundled Manrope. A small, centered “by” with the supplied
VoiceLab SVG wordmark sits underneath it. Finder provides the actual draggable
icons and their labels; none of the character art is an interactive control.
Both standard and Retina TIFF representations use the same logical coordinates.
The mounted disk uses Echo’s actual app icon, including Finder’s volume/proxy icon.
Finder controls the title/proxy icon placement and visibility; no global Finder
preferences are changed.

The four character assets live in `scripts/installer/Assets`: the original, a
flying pose, a wink and a curious peeking pose. They were created using the built-in
image-generation tool, with prompts recorded in `Assets/ARTWORK.md`. The flying
pose sits above the drag path, the wink beside the instruction, and the other
two peek behind the native Applications icon. AppKit assembles these individual
images and the instruction into Finder's static canvas at build time. Release
builds use these checked-in assets
and never call an image service.

`scripts/create-installer-dmg.sh APP OUTPUT.dmg` creates an **unsigned local
installer** from an already signed app. `scripts/release.sh notarize` invokes it,
then performs the existing Developer ID DMG signature, notarization, stapling,
checksum and publication stages. Never publish the helper's unsigned output.

The helper uses only Xcode's compiler, Apple frameworks/tools, Python's standard
library and repository assets. It does not download packages, control Finder,
request Automation permission, install fonts globally, launch Echo, or write to
Applications. Example local preview:

```sh
scripts/create-installer-dmg.sh \
  build/releases/Echo-2.0.0-102-universal-test/export/Echo.app \
  /tmp/echo-installer-preview.dmg
```

Use an existing app and a new output path. Opening that preview is a separate
manual step; `open /tmp/echo-installer-preview.dmg` mounts it in Finder. A normal
release should be tested from a browser download as well, to exercise quarantine
and Gatekeeper.

## Packaging order and checks

1. Copy the signed app unchanged into private temporary staging and add the
   Applications symlink plus hidden `.background` resources.
2. Render the background using the checked-in Manrope fonts. Create a writable
   **HFS+** image. This mature installer format supports persistent Finder
   auto-open metadata on Apple Silicon and Intel; the installed app still runs
   normally from an APFS startup disk.
3. Generate a native background alias on the mounted image. Remove build-host
   paths and the recursive alias to the temporary source DMG. Preserve the
   image's file/volume identity and its relative background path.
4. Write `.DS_Store` with fixed window bounds, icon positions, icon view and
   hidden toolbar/sidebar. Set only the volume's auto-open directory using
   `getattrlist`/`setattrlist`. This avoids the removed Apple Silicon `bless
   --openfolder` operation. Copy the app’s declared ICNS resource to hidden
   `.VolumeIcon.icns` and set the root folder’s `kHasCustomIcon` flag, preserving
   all other Finder flags and the separate volume auto-open metadata.
5. Verify the app signature, detach without force, and compress to ULFO/LZFSE.
6. Mount that final image read-only at a different path. Resolve its background
   alias using macOS, verify persistent auto-open metadata, compare the volume
   icon byte-for-byte with the app’s declared icon and check its custom-icon
   flag, and verify the embedded app's deep signature again. Only then atomically
   create the new output file. Existing output files are never overwritten.

If conversion or verification fails, no completed image is returned. Scratch
images are detached during normal and error cleanup. A mount that cannot be
cleanly detached is left in its private directory with an actionable diagnostic;
the helper never deletes a mounted filesystem or forces it off disk.

The *layout* is deterministic. Whole DMG bytes vary with filesystem identities,
creation times, code signatures and notarization tickets. Signature/checksum
creation must continue to happen after final stapling.

## Validation

`bash scripts/test-release.sh` includes independent layout decoding and tests for
portable aliases, invalid/truncated metadata, interrupted artwork generation,
partial conversion and successful retry without duplicate notarization.
The native build also verifies alias resolution and auto-open persistence after
conversion on every release, including the exact volume icon and its Finder
flag. Finder is not opened during build-time checks.

Run `python3 Tests/InstallerVolumeIconRegression.py` for native macOS integration
coverage. It compiles the volume-icon helper and creates private HFS+ scratch
images to check conversion/remount persistence, unchanged app files, preservation
of unrelated Finder flags, rejected unsafe icon paths, and detection of missing
or altered metadata. It never opens Finder or accesses installed apps.

Manually inspect each installer design change in Finder on supported macOS
versions: light/dark appearance, standard/Retina displays, a small display, and a
second already-mounted volume named Echo. Confirm that only Echo and Applications
are visible, the app can be dragged into Applications, and macOS applies its
normal overwrite/authentication/Gatekeeper behavior. Do not replace a developer's
installed app just to verify the artwork.

Finder metadata is not a stable public document format. Its small writer is
intentionally limited to a single page with the six records needed here, rather
than an editor for arbitrary `.DS_Store` files. The native Carbon alias API is
isolated in the build tool; it is not linked into Echo. Current SDK deprecation
warnings for these aliases are suppressed explicitly. Other compiler warnings
are errors. A future SDK removing the API will fail packaging visibly.

Format references: [ds_store](https://ds-store.readthedocs.io/en/latest/),
[mac_alias](https://github.com/dmgbuild/mac_alias),
[Apple's HFS+ volume header](https://developer.apple.com/library/archive/technotes/tn/tn1150.html#VolumeHeader),
and the installed `getattrlist(2)` / `setattrlist(2)` manual pages.
