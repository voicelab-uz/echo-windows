#!/bin/bash
# Build an unsigned installer; release.sh signs and notarizes the final bytes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $# == 2 ]] || { printf 'Usage: %s APP OUTPUT.dmg\n' "$0" >&2; exit 1; }
app=$1
output=$2
[[ -d "$app/Contents" && ! -e "$output" && -d "$(dirname "$output")" ]] || {
    printf 'Expected an app bundle and a new DMG path in an existing directory.\n' >&2; exit 1;
}
stage=$(mktemp -d "${TMPDIR:-/tmp}/echo-installer.XXXXXX")
mount=
output_stage=
cleanup() {
    if [[ -n "$mount" ]]; then
        if hdiutil detach "$mount" >/dev/null 2>&1; then mount=; fi
    fi
    if [[ -z "$mount" ]]; then
        rm -rf "$stage"
    else
        printf 'Installer image is still mounted at %s; keeping its scratch directory.\n' "$mount" >&2
    fi
    [[ -z "$output_stage" ]] || rm -f "$output_stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$stage/content/.background" "$stage/mount"
ditto "$app" "$stage/content/Echo.app"
ln -s /Applications "$stage/content/Applications"
xcrun clang -fobjc-arc -Werror -Wno-deprecated-declarations \
    -framework AppKit -framework CoreText -framework CoreServices \
    "$ROOT/scripts/installer/InstallerArtwork.m" -o "$stage/artwork"
xcrun clang -fobjc-arc -Werror -framework AppKit -framework CoreServices \
    "$ROOT/scripts/installer/InstallerVolumeIcon.m" -o "$stage/volume-icon"
"$stage/artwork" background "$ROOT/Voicelab/Features/Onboarding/Experience/Resources/Fonts" \
    "$stage/content/.background/background.tiff" "$ROOT/scripts/installer/Assets/echo-character.png"
# The background alias must reference the *image's* filesystem, not the host's
# source folder. Configure the writable image, then convert it before signing.
hdiutil create -volname Echo -fs HFS+ -format UDRW -srcfolder "$stage/content" "$stage/writable.dmg"
mount="$stage/mount"
hdiutil attach -nobrowse -noautoopen -mountpoint "$mount" "$stage/writable.dmg" >/dev/null
"$stage/artwork" alias "$mount/.background/background.tiff" "$stage/background.alias"
python3 "$ROOT/scripts/installer/layout.py" "$mount" "$stage/background.alias"
"$stage/artwork" autoopen "$mount"
"$stage/volume-icon" apply "$mount"
codesign --verify --deep --strict "$mount/Echo.app"
# Never force-detach a filesystem with pending writes; an error leaves the
# private mount available for inspection and cannot publish a partial image.
for attempt in 1 2 3; do
    if hdiutil detach "$mount" >/dev/null; then mount=; break; fi
    sleep 1
done
[[ -z "$mount" ]] || { printf 'Could not cleanly detach installer image.\n' >&2; exit 1; }
hdiutil convert "$stage/writable.dmg" -format ULFO -o "$stage/Echo.dmg"
# Verify the actual converted image at a new path before it can be signed.
mount="$stage/remounted"
mkdir "$mount"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount" "$stage/Echo.dmg" >/dev/null
"$stage/artwork" verify-alias "$stage/background.alias" "$mount/.background/background.tiff"
"$stage/artwork" verify-autoopen "$mount"
"$stage/volume-icon" verify "$mount"
codesign --verify --deep --strict "$mount/Echo.app"
hdiutil detach "$mount" >/dev/null
mount=
output_stage=$(mktemp "$(dirname "$output")/.echo-installer.XXXXXX")
cp "$stage/Echo.dmg" "$output_stage"
cmp -s "$stage/Echo.dmg" "$output_stage"
# A hard link creates the final path exclusively, even if a concurrent caller
# creates it after the initial check. Staging is on the destination filesystem.
ln "$output_stage" "$output"
