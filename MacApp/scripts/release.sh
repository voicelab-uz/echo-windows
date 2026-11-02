#!/bin/bash
# macOS system Bash (3.2+) and Xcode tools only. See docs/CDN_RELEASE.md.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUNDLE_ID=uz.voicelab.desktop
release_lock=
package_stage=
verification_dir=
verification_mount=
profile_tools_dir=
push_profile_uuid=
push_profile_sha=

die() { printf 'Release error: %s\n' "$*" >&2; exit 1; }
note() { printf '\n%s\n' "$*"; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }
cleanup() {
    if [[ -n "$verification_mount" ]]; then
        if hdiutil detach "$verification_mount" >/dev/null 2>&1; then
            verification_mount=
        else
            printf 'Could not detach verification image at %s; leaving its directory for manual cleanup.\n' "$verification_mount" >&2
        fi
    fi
    if [[ -z "$verification_mount" && -n "$verification_dir" ]]; then rm -rf "$verification_dir"; fi
    [[ -z "$package_stage" ]] || rm -rf "$package_stage"
    [[ -z "$profile_tools_dir" ]] || rm -rf "$profile_tools_dir"
    [[ -z "$release_lock" ]] || rmdir "$release_lock"
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<'HELP'
Usage: scripts/release.sh check
       scripts/release.sh {build|sign|notarize|package|all} VERSION BUILD_NUMBER

  check     Check local Xcode tools and the selected Developer ID identity.
  build     Archive Release with explicit version, architectures and signing.
  sign      Export the archive using Developer ID and verify the signed app.
  notarize  Notarize/staple app, then signed DMG; resume saved submissions.
  package   Verify stapled app and DMG; create immutable DMG/checksum/metadata.
  all       Run build, sign, notarize and package in sequence.

Required environment: ECHO_TEAM_ID, ECHO_SIGNING_IDENTITY (certificate SHA-1).
Notarization also requires ECHO_NOTARY_PROFILE (a notarytool Keychain profile).
Optional: ECHO_ARCHS (default "arm64 x86_64"), ECHO_NOTARY_KEYCHAIN,
          ECHO_NOTARY_TIMEOUT (default "30m").
Push release: ECHO_PUSH_ENABLED=1 and ECHO_PUSH_PROFILE (external absolute path).
              Default 0 preserves non-push builds; profiles/keys never enter Git.
Updates: ECHO_UPDATE_CHANNEL, ECHO_UPDATE_FEED_URL,
         ECHO_UPDATE_RELEASE_BASE_URL, ECHO_SPARKLE_PUBLIC_KEY.
Stable/beta require clean source and ECHO_PREVIOUS_BUILD.
Test permits dirty source only with ECHO_ALLOW_DIRTY_TEST=1.

Load Configuration/release.env.local as described in docs/CDN_RELEASE.md.
Output is local only; this script never uploads to your CDN.
HELP
}

validate_config() {
    [[ "${ECHO_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || die 'Set ECHO_TEAM_ID to your 10-character Apple Team ID.'
    [[ "${ECHO_SIGNING_IDENTITY:-}" =~ ^[[:xdigit:]]{40}$ ]] || die 'Set ECHO_SIGNING_IDENTITY to a Developer ID Application certificate SHA-1 from security find-identity.'
    ECHO_SIGNING_IDENTITY=$(printf '%s' "$ECHO_SIGNING_IDENTITY" | tr 'a-f' 'A-F')
    ECHO_PUSH_ENABLED=${ECHO_PUSH_ENABLED:-0}
    case "$ECHO_PUSH_ENABLED" in 0|1) ;; *) die 'ECHO_PUSH_ENABLED must be 0 or 1.' ;; esac
    if [[ "$ECHO_PUSH_ENABLED" == 1 ]]; then
        [[ "${ECHO_PUSH_PROFILE:-}" == /* && -f "$ECHO_PUSH_PROFILE" ]] || die 'Push is required: set ECHO_PUSH_PROFILE to an external Developer ID provisioning profile.'
    else
        [[ -z "${ECHO_PUSH_PROFILE:-}" ]] || die 'A push profile was provided but ECHO_PUSH_ENABLED is not 1.'
    fi
    case "${ECHO_ARCHS:-arm64 x86_64}" in
        'arm64 x86_64'|'x86_64 arm64') architectures=(arm64 x86_64); arch_label=universal ;;
        arm64) architectures=(arm64); arch_label=arm64 ;;
        x86_64) architectures=(x86_64); arch_label=x86_64 ;;
        *) die 'ECHO_ARCHS must be "arm64 x86_64", "arm64", or "x86_64".' ;;
    esac
    [[ "$arch_label" == universal ]] || die 'Updater releases must contain arm64 and x86_64.'
    python3 "$ROOT/scripts/update_release.py" validate-config
    ECHO_UPDATE_CHANNEL=${ECHO_UPDATE_CHANNEL:?}
    ECHO_NOTARY_TIMEOUT=${ECHO_NOTARY_TIMEOUT:-30m}
    [[ "$ECHO_NOTARY_TIMEOUT" =~ ^[1-9][0-9]*[smh]?$ ]] || die 'ECHO_NOTARY_TIMEOUT must be a duration such as 30m.'
}

preflight() {
    [[ "$(uname -s)" == Darwin ]] || die 'Release builds require macOS.'
    local tool
    for tool in xcodebuild xcrun codesign security spctl ditto shasum plutil git python3 hdiutil; do
        command -v "$tool" >/dev/null || die "Missing tool: $tool"
    done
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
    xcrun --find lipo >/dev/null
    xcodebuild -version
    security find-identity -v -p codesigning | awk \
        -v fingerprint="$ECHO_SIGNING_IDENTITY" -v team="$ECHO_TEAM_ID" '
        $2 == fingerprint && index($0, "\"Developer ID Application: ") &&
        index($0, "(" team ")\"") { found = 1 }
        END { exit !found }
    ' || die 'No valid Developer ID Application identity/private key for this fingerprint and team is available in the Keychain search list.'
    note "Signing identity available. Architectures: ${architectures[*]}"
    if [[ "$ECHO_PUSH_ENABLED" == 1 ]]; then
        profile_tools_dir=$(mktemp -d "${TMPDIR:-/tmp}/echo-profile-tools.XXXXXX")
        xcrun swiftc -module-cache-path "$profile_tools_dir/module-cache" \
            "$ROOT/scripts/verify-provisioning-profile.swift" -o "$profile_tools_dir/verify-profile"
        inspect_push_profile "$ECHO_PUSH_PROFILE" --external-to "$ROOT" > "$profile_tools_dir/metadata.json"
        push_profile_uuid=$(plutil -extract uuid raw -o - "$profile_tools_dir/metadata.json")
        push_profile_sha=$(plutil -extract sha256 raw -o - "$profile_tools_dir/metadata.json")
        note "Verified production push profile: $push_profile_uuid"
    fi
}

inspect_push_profile() {
    python3 "$ROOT/scripts/push_profile.py" "$1" \
        --verifier "$profile_tools_dir/verify-profile" --team "$ECHO_TEAM_ID" \
        --bundle "$BUNDLE_ID" --certificate "$ECHO_SIGNING_IDENTITY" "${@:2}"
}

prepare_push_profile() {
    [[ "$ECHO_PUSH_ENABLED" == 1 ]] || return 0
    inspect_push_profile "$ECHO_PUSH_PROFILE" --external-to "$ROOT" \
        --expected-sha256 "$push_profile_sha" \
        --stage "$work/push-profile.provisionprofile" --install > "$profile_tools_dir/staged.json"
    [[ "$(plutil -extract sha256 raw -o - "$profile_tools_dir/staged.json")" == "$push_profile_sha" ]] || die 'Push profile changed after preflight. Use a new build attempt.'
}

verify_push_profile() {
    local candidate="$1" aps embedded="$1/Contents/embedded.provisionprofile"
    aps=$(plist_value "$work/entitlements.plist" com.apple.developer.aps-environment 2>/dev/null || true)
    if [[ "$ECHO_PUSH_ENABLED" == 1 ]]; then
        [[ "$aps" == production && -f "$embedded" ]] || die 'Push-enabled app must embed its production profile and signed APS entitlement.'
        [[ "$(plist_value "$work/entitlements.plist" com.apple.application-identifier)" == "$ECHO_TEAM_ID.$BUNDLE_ID" ]] || die 'Signed push app identifier does not match the profile.'
        [[ "$(plist_value "$work/entitlements.plist" com.apple.developer.team-identifier)" == "$ECHO_TEAM_ID" ]] || die 'Signed push team does not match the profile.'
        inspect_push_profile "$embedded" > "$profile_tools_dir/embedded.json"
        [[ "$(plutil -extract sha256 raw -o - "$profile_tools_dir/embedded.json")" == "$push_profile_sha" ]] || die 'Embedded push profile differs from the selected validated profile.'
    else
        [[ -z "$aps" && ! -e "$embedded" ]] || die 'Unexpected provisioning profile or APS entitlement in a non-push release.'
    fi
}

require_notary_config() {
    [[ -n "${ECHO_NOTARY_PROFILE:-}" ]] || die 'Set ECHO_NOTARY_PROFILE to a stored notarytool Keychain profile.'
    notary_auth=(--keychain-profile "$ECHO_NOTARY_PROFILE")
    if [[ -n "${ECHO_NOTARY_KEYCHAIN:-}" ]]; then
        notary_auth+=(--keychain "$ECHO_NOTARY_KEYCHAIN")
    fi
}

verify_architectures() {
    local executable="$1" actual_archs expected_archs
    actual_archs=$(xcrun lipo -archs "$executable" | tr ' ' '\n' | LC_ALL=C sort)
    expected_archs=$(printf '%s\n' "${architectures[@]}" | LC_ALL=C sort)
    [[ "$actual_archs" == "$expected_archs" ]] || die "Unexpected binary architectures: $executable ($actual_archs)"
}

verify_code() {
    local candidate="$1" executable="$2" require_runtime="$3" debug_entitlement
    codesign --verify --strict --verbose=2 "$candidate"
    codesign --display --verbose=4 "$candidate" 2> "$work/signature.txt"
    grep -q '^Authority=Developer ID Application:' "$work/signature.txt" || die "Not Developer ID signed: $candidate"
    grep -qx "TeamIdentifier=$ECHO_TEAM_ID" "$work/signature.txt" || die "Wrong signing team: $candidate"
    if [[ "$require_runtime" == true ]]; then
        grep -Eq '^CodeDirectory .*flags=.*runtime' "$work/signature.txt" || die "Hardened Runtime missing: $candidate"
    fi
    grep -Eq '^Timestamp=.+' "$work/signature.txt" || die "Secure timestamp missing: $candidate"
    if [[ -n "$executable" ]]; then
        verify_architectures "$executable"
        codesign --display --entitlements :- "$candidate" > "$work/entitlements.plist" 2> "$work/entitlements.log"
        # Frameworks and command-line helpers legitimately have no entitlements.
        if [[ -s "$work/entitlements.plist" ]]; then
            plutil -lint "$work/entitlements.plist" >/dev/null
            debug_entitlement=$(plist_value "$work/entitlements.plist" com.apple.security.get-task-allow 2>/dev/null || true)
            [[ -z "$debug_entitlement" || "$debug_entitlement" == false ]] || die "Debug entitlement: $candidate"
        fi
    fi
}

verify_app() {
    local candidate="$1" phase="${2:-exported}" info executable relative nested
    info="$candidate/Contents/Info.plist"
    [[ -f "$info" ]] || die "Missing app: $candidate"
    [[ "$(plist_value "$info" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || die 'Unexpected bundle identifier.'
    [[ "$(plist_value "$info" CFBundleShortVersionString)" == "$release_version" ]] || die 'App version does not match this release.'
    [[ "$(plist_value "$info" CFBundleVersion)" == "$release_build" ]] || die 'App build number does not match this release.'
    [[ -n "$(plist_value "$info" NSMicrophoneUsageDescription)" ]] || die 'Missing microphone purpose description.'
    python3 "$ROOT/scripts/update_release.py" validate-app "$candidate"
    codesign --verify --deep --strict --verbose=2 "$candidate"
    executable=$(plist_value "$info" CFBundleExecutable)
    verify_code "$candidate" "$candidate/Contents/MacOS/$executable" true
    [[ "$(plist_value "$work/entitlements.plist" com.apple.security.device.audio-input)" == true ]] || die 'Microphone entitlement is missing.'
    verify_push_profile "$candidate"
    # Inspect every nested Mach-O, not only the outer signature. Never deep re-sign.
    python3 "$ROOT/scripts/update_release.py" code-inventory "$candidate" > "$work/code-inventory.txt"
    while IFS= read -r relative; do
        [[ -n "$relative" ]] || continue
        nested="$candidate/$relative"
        # Xcode exportArchive re-signs Sparkle's original nested helpers. At the
        # archive stage validate structure/architectures/signature integrity only;
        # enforce our identity/runtime/timestamps after Developer ID export.
        if [[ "$phase" == archive ]]; then
            codesign --verify --strict --verbose=2 "$nested"
            verify_architectures "$nested"
            continue
        fi
        # MH_DYLIB framework code is not a process; its hosts need hardened runtime.
        case "$relative" in */Sparkle.framework/Versions/*/Sparkle) verify_code "$nested" "$nested" false ;;
            *) verify_code "$nested" "$nested" true ;;
        esac
    done < "$work/code-inventory.txt"
}

build_release() {
    [[ ! -e "$archive" && ! -e "$work/source.plist" ]] || die "Build already started at $work. Use a new build number, or explicitly remove the failed work directory before retrying."
    local dirty=false
    if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
        dirty=true
        [[ "$ECHO_UPDATE_CHANNEL" == test && "${ECHO_ALLOW_DIRTY_TEST:-0}" == 1 ]] || die 'Release source must be clean. Only test builds may opt in with ECHO_ALLOW_DIRTY_TEST=1.'
        note 'Explicit test build from dirty source; production feeds will reject it.'
    fi
    prepare_push_profile
    # Reject dirty production source before creating the resumable build marker.
    plutil -create xml1 "$work/source.plist"
    plutil -insert commit -string "$(git -C "$ROOT" rev-parse HEAD)" "$work/source.plist"
    plutil -insert dirty -bool "$dirty" "$work/source.plist"
    plutil -insert channel -string "$ECHO_UPDATE_CHANNEL" "$work/source.plist"
    plutil -insert feedURL -string "$ECHO_UPDATE_FEED_URL" "$work/source.plist"
    plutil -insert publicKey -string "$ECHO_SPARKLE_PUBLIC_KEY" "$work/source.plist"
    plutil -insert releaseBaseURL -string "$ECHO_UPDATE_RELEASE_BASE_URL" "$work/source.plist"
    plutil -insert pushEnabled -string "$ECHO_PUSH_ENABLED" "$work/source.plist"
    plutil -insert pushProfileSHA256 -string "$push_profile_sha" "$work/source.plist"
    local app_entitlements=Configuration/Voicelab.entitlements
    if [[ "$ECHO_PUSH_ENABLED" == 1 ]]; then app_entitlements=Configuration/Voicelab-Push.entitlements; fi
    note "Archiving $release_name"
    xcodebuild -project "$ROOT/Voicelab.xcodeproj" -scheme Voicelab \
        -configuration Release -destination 'generic/platform=macOS' \
        -derivedDataPath "$work/DerivedData" -archivePath "$archive" \
        "DEVELOPMENT_TEAM=$ECHO_TEAM_ID" \
        CODE_SIGN_STYLE=Manual \
        "CODE_SIGN_IDENTITY=$ECHO_SIGNING_IDENTITY" \
        "ECHO_APP_ENTITLEMENTS=$app_entitlements" \
        "ECHO_APP_PROVISIONING_PROFILE_UUID=$push_profile_uuid" \
        "CODE_SIGN_IDENTITY[sdk=macosx*][target=EchoWakeHelper]=" \
        "CODE_SIGN_STYLE[sdk=macosx*][target=EchoWakeHelper]=Automatic" \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp \
        ENABLE_HARDENED_RUNTIME=YES ENABLE_APP_SANDBOX=NO \
        "MARKETING_VERSION=$release_version" "CURRENT_PROJECT_VERSION=$release_build" \
        "ECHO_UPDATE_CHANNEL=$ECHO_UPDATE_CHANNEL" \
        "ECHO_UPDATE_FEED_URL=$ECHO_UPDATE_FEED_URL" \
        "ECHO_SPARKLE_PUBLIC_KEY=$ECHO_SPARKLE_PUBLIC_KEY" \
        "ARCHS=${architectures[*]}" ONLY_ACTIVE_ARCH=NO archive 2>&1 | tee "$work/archive.log"
    verify_app "$archive/Products/Applications/Echo.app" archive
}

sign_release() {
    [[ -d "$archive" ]] || die 'Run the build stage first.'
    [[ ! -e "$work/export" ]] || die 'Export already exists. Resume notarize/package, or explicitly remove the failed export directory before retrying sign.'
    [[ ! -e "$work/notary-upload.zip" ]] || die 'A notarization upload already exists; do not re-sign this release.'
    prepare_push_profile
    verify_app "$archive/Products/Applications/Echo.app" archive
    local options="$work/ExportOptions.plist"
    plutil -create xml1 "$options"
    plutil -insert method -string developer-id "$options"
    plutil -insert destination -string export "$options"
    plutil -insert signingStyle -string manual "$options"
    plutil -insert signingCertificate -string "$ECHO_SIGNING_IDENTITY" "$options"
    plutil -insert teamID -string "$ECHO_TEAM_ID" "$options"
    if [[ "$ECHO_PUSH_ENABLED" == 1 ]]; then
        python3 - "$options" "$BUNDLE_ID" "$push_profile_uuid" <<'PYPROFILE'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
options = plistlib.loads(path.read_bytes())
options["provisioningProfiles"] = {sys.argv[2]: sys.argv[3]}
path.write_bytes(plistlib.dumps(options))
PYPROFILE
    fi
    note 'Exporting with Developer ID signing'
    xcodebuild -exportArchive -archivePath "$archive" \
        -exportPath "$work/export" -exportOptionsPlist "$options" 2>&1 | tee "$work/export.log"
    verify_app "$app"
}

notarize_upload() {
    local upload="$1" prefix="$2" submission="$work/$2-submission.json" submission_id result wait_exit=0
    if [[ ! -e "$submission" ]]; then
        # This marker prevents duplicate submissions after an ambiguous network failure.
        [[ ! -e "$work/$prefix-upload.sha256" ]] || die 'Upload was prepared without a saved submission. Recover its ID with notarytool history/info; do not blindly resubmit.'
        shasum -a 256 "$upload" > "$work/$prefix-upload.sha256"
        xcrun notarytool submit "$upload" "${notary_auth[@]}" \
            --output-format json > "$submission" || die "Submission outcome unknown. Recover using $submission and notarytool history/info."
    fi
    submission_id=$(plutil -extract id raw -o - "$submission") || die 'Missing submission ID; recover it using notarytool history/info.'
    [[ "$submission_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || die 'Invalid saved notarization submission ID.'
    shasum -a 256 -c "$work/$prefix-upload.sha256" || die 'Notarization upload has changed.'
    if [[ -f "$work/$prefix-result.json" ]] && [[ "$(plutil -extract status raw -o - "$work/$prefix-result.json" 2>/dev/null)" == Accepted ]]; then
        return
    fi
    note "Waiting for notarization: $submission_id (timeout $ECHO_NOTARY_TIMEOUT)"
    xcrun notarytool wait "$submission_id" "${notary_auth[@]}" \
        --timeout "$ECHO_NOTARY_TIMEOUT" --output-format json > "$work/$prefix-result.json" || wait_exit=$?
    result=$(plutil -extract status raw -o - "$work/$prefix-result.json" 2>/dev/null || true)
    if [[ "$result" == Accepted || "$result" == Invalid || "$result" == Rejected ]]; then
        xcrun notarytool log "$submission_id" "${notary_auth[@]}" "$work/$prefix-log.json" || \
            printf 'Notary log unavailable; retrieve it later using the saved submission ID.\n' >&2
    fi
    [[ "$wait_exit" == 0 && "$result" == Accepted ]] || die "Notarization is not accepted (status: ${result:-unknown}). Rerun notarize to resume a timeout; inspect logs before retrying a rejection."
}

notarize_release() {
    require_notary_config
    verify_app "$app"
    if [[ ! -e "$work/notary-upload.zip" ]]; then
        [[ ! -e "$work/notary-submission.json" ]] || die 'Submitted app archive is missing.'
        verification_dir=$(mktemp -d "$work/notary-packaging.XXXXXX")
        ditto -c -k --sequesterRsrc --keepParent "$app" "$verification_dir/notary-upload.zip"
        mv "$verification_dir/notary-upload.zip" "$work/notary-upload.zip"
        rm -rf "$verification_dir"
        verification_dir=
    fi
    notarize_upload "$work/notary-upload.zip" notary
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=4 "$app"
    # Keep the exact submitted DMG immutable. Staple a copy, so interrupted/resumed
    # notarization continues checking the bytes Apple actually received.
    if [[ ! -e "$work/dmg-upload.dmg" ]]; then
        [[ ! -e "$work/dmg-submission.json" ]] || die 'Submitted DMG is missing.'
        verification_dir=$(mktemp -d "${TMPDIR:-/tmp}/echo-release-dmg.XXXXXX")
        /bin/bash "$ROOT/scripts/create-installer-dmg.sh" "$app" "$verification_dir/Echo.dmg"
        codesign --force --sign "$ECHO_SIGNING_IDENTITY" --timestamp "$verification_dir/Echo.dmg"
        verify_code "$verification_dir/Echo.dmg" '' false
        # hdiutil stages outside the build tree to avoid APFS source-volume busy
        # errors. Copy back into same-filesystem staging before atomic promotion.
        package_stage=$(mktemp -d "$work/dmg-publish.XXXXXX")
        cp "$verification_dir/Echo.dmg" "$package_stage/Echo.dmg"
        cmp -s "$verification_dir/Echo.dmg" "$package_stage/Echo.dmg" || die 'DMG copy changed during staging.'
        mv "$package_stage/Echo.dmg" "$work/dmg-upload.dmg"
        rm -rf "$package_stage"
        package_stage=
        rm -rf "$verification_dir"
        verification_dir=
    fi
    notarize_upload "$work/dmg-upload.dmg" dmg
    if [[ ! -e "$work/Echo.dmg" ]]; then
        cp "$work/dmg-upload.dmg" "$work/dmg-stapling.dmg"
        xcrun stapler staple "$work/dmg-stapling.dmg"
        xcrun stapler validate "$work/dmg-stapling.dmg"
        mv "$work/dmg-stapling.dmg" "$work/Echo.dmg"
    fi
    xcrun stapler validate "$work/Echo.dmg"
    note 'App and DMG notarized; final DMG ticket stapled.'
}

package_release() {
    [[ -f "$work/notary-result.json" ]] || die 'Run the notarize stage first.'
    [[ "$(plutil -extract status raw -o - "$work/notary-result.json")" == Accepted ]] || die 'Notarization has not been accepted.'
    verify_app "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=4 "$app"
    [[ ! -e "$destination" ]] || die "Refusing to overwrite $destination"
    mkdir -p "$ROOT/dist"
    package_stage=$(mktemp -d "$ROOT/dist/.$release_name.XXXXXX")
    [[ -f "$work/dmg-result.json" && -f "$work/Echo.dmg" ]] || die 'Signed, notarized DMG is missing.'
    [[ "$(plutil -extract status raw -o - "$work/dmg-result.json")" == Accepted ]] || die 'DMG notarization has not been accepted.'
    local filename="$release_name.dmg" checksum metadata="$package_stage/release.json" arch arch_index=0
    cp "$work/Echo.dmg" "$package_stage/$filename"
    verify_code "$package_stage/$filename" '' false
    xcrun stapler validate "$package_stage/$filename"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$package_stage/$filename"
    verification_dir=$(mktemp -d "$work/package-check.XXXXXX")
    verification_mount="$verification_dir/mount"
    mkdir "$verification_mount"
    hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$verification_mount" "$package_stage/$filename" >/dev/null
    verify_app "$verification_mount/Echo.app"
    xcrun stapler validate "$verification_mount/Echo.app"
    spctl --assess --type execute --verbose=4 "$verification_mount/Echo.app"
    hdiutil detach "$verification_mount" >/dev/null
    verification_mount=
    rm -rf "$verification_dir"
    verification_dir=
    (cd "$package_stage" && shasum -a 256 "$filename" > SHA256SUMS.txt)
    checksum=$(awk '{print $1}' "$package_stage/SHA256SUMS.txt")
    plutil -create xml1 "$metadata"
    plutil -insert schemaVersion -integer 1 "$metadata"
    plutil -insert version -string "$release_version" "$metadata"
    plutil -insert build -string "$release_build" "$metadata"
    plutil -insert bundleIdentifier -string "$BUNDLE_ID" "$metadata"
    plutil -insert teamID -string "$ECHO_TEAM_ID" "$metadata"
    plutil -insert minimumSystemVersion -string "$(plist_value "$app/Contents/Info.plist" LSMinimumSystemVersion)" "$metadata"
    plutil -insert architectures -array "$metadata"
    for arch in "${architectures[@]}"; do
        plutil -insert "architectures.$arch_index" -string "$arch" "$metadata"
        arch_index=$((arch_index + 1))
    done
    plutil -insert filename -string "$filename" "$metadata"
    plutil -insert sha256 -string "$checksum" "$metadata"
    plutil -insert bytes -integer "$(stat -f %z "$package_stage/$filename")" "$metadata"
    plutil -insert sourceCommit -string "$(plist_value "$work/source.plist" commit)" "$metadata"
    plutil -insert sourceDirty -bool "$(plist_value "$work/source.plist" dirty)" "$metadata"
    plutil -insert notarizationID -string "$(plutil -extract id raw -o - "$work/notary-submission.json")" "$metadata"
    plutil -insert dmgNotarizationID -string "$(plutil -extract id raw -o - "$work/dmg-submission.json")" "$metadata"
    plutil -insert channel -string "$ECHO_UPDATE_CHANNEL" "$metadata"
    plutil -insert feedURL -string "$ECHO_UPDATE_FEED_URL" "$metadata"
    plutil -insert publicEDKey -string "$ECHO_SPARKLE_PUBLIC_KEY" "$metadata"
    plutil -insert releaseBaseURL -string "$ECHO_UPDATE_RELEASE_BASE_URL" "$metadata"
    plutil -insert sparkleVersion -string 2.10.1 "$metadata"
    plutil -insert createdAt -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$metadata"
    plutil -convert json -r "$metadata"
    mv "$package_stage" "$destination"
    package_stage=
    note "Verified release ready: $destination"
    printf 'Next: scripts/update_release.py prepare --help (signed feed and publication plan).\n'
}

action=${1:-help}
case "$action" in
    help|-h|--help) usage; exit 0 ;;
    check) [[ $# == 1 ]] || die 'Usage: scripts/release.sh check' ;;
    build|sign|notarize|package|all) [[ $# == 3 ]] || die 'Supply a version and build number; see --help.' ;;
    *) die "Unknown command: $action" ;;
esac
validate_config
if [[ "$action" == check ]]; then preflight; exit 0; fi
release_version=$2
release_build=$3
[[ "$release_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die 'Version must have two or three numeric components, e.g. 1.0.0.'
[[ "$release_build" =~ ^[1-9][0-9]*$ ]] || die 'Build number must be a positive integer.'
python3 "$ROOT/scripts/update_release.py" validate-build "$release_build"
release_name="Echo-$release_version-$release_build-$arch_label"
# Test artifacts cannot be confused with production archives.
if [[ "$ECHO_UPDATE_CHANNEL" != stable ]]; then release_name="$release_name-$ECHO_UPDATE_CHANNEL"; fi
work="$ROOT/build/releases/$release_name"
archive="$work/Echo.xcarchive"
app="$work/export/Echo.app"
destination="$ROOT/dist/$release_name"
[[ ! -e "$destination" ]] || die "Release already packaged: $destination. Use a new build number."
if [[ "$action" == all || "$action" == notarize ]]; then require_notary_config; fi
preflight
mkdir -p "$ROOT/build/releases"
if mkdir "$work.lock" 2>/dev/null; then
    release_lock="$work.lock"
else
    die "Another release process owns $work.lock. If interrupted forcibly, verify it has stopped before removing that empty lock directory."
fi
mkdir -p "$work"
if [[ "$action" != build && "$action" != all ]]; then
    [[ -f "$work/source.plist" ]] || die 'Missing build source record.'
    recorded_push=$(plist_value "$work/source.plist" pushEnabled 2>/dev/null || printf '0')
    recorded_profile=$(plist_value "$work/source.plist" pushProfileSHA256 2>/dev/null || true)
    [[ "$recorded_push" == "$ECHO_PUSH_ENABLED" && "$recorded_profile" == "$push_profile_sha" ]] || die 'Push configuration changed after archive. Use the original profile/configuration or a new build number.'
    [[ "$(plist_value "$work/source.plist" channel)" == "$ECHO_UPDATE_CHANNEL" &&
       "$(plist_value "$work/source.plist" feedURL)" == "$ECHO_UPDATE_FEED_URL" &&
       "$(plist_value "$work/source.plist" publicKey)" == "$ECHO_SPARKLE_PUBLIC_KEY" &&
       "$(plist_value "$work/source.plist" releaseBaseURL)" == "$ECHO_UPDATE_RELEASE_BASE_URL" ]] || die 'Release configuration changed after build. Use the original configuration or a new build number.'
fi
case "$action" in
    all) build_release; sign_release; notarize_release; package_release ;;
    build) build_release ;;
    sign) sign_release ;;
    notarize) notarize_release ;;
    package) package_release ;;
esac
