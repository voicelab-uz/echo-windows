# Echo CDN release

This workflow produces a Developer ID-signed, notarized, stapled DMG containing
`Echo.app`. It reuses the previous VoiceLab app's `uz.voicelab.desktop` bundle
identifier and publishing team. Normal Xcode Run/Debug uses Apple Development
signing; release archives use Developer ID. It does not submit to the Mac App
Store or upload to a CDN.

## Shared release identifiers

The CDN publisher was confirmed on October 21, 2026. These identifiers are safe
to commit and are included here so another developer can configure a build Mac.
They do not grant signing or notarization access by themselves.

| Setting | Confirmed value |
|---|---|
| Apple Developer Team ID | `FWCSVFT76D` |
| Developer ID Application certificate | `Developer ID Application: Otabek Nurmatov (FWCSVFT76D)` |
| Certificate SHA-1 fingerprint | `B443163B7E1C67F9F7FF981137A23B90887EB3AF` |
| Certificate expiration | July 26, 2031 |
| App Store Connect team key name / ID | `VoiceLab` / `8VJWSFC9U4` |
| App Store Connect Issuer ID | `d7b6dbe8-1f6c-4cca-b742-47302decdac3` |
| Local notarization profile name | `echo-notary` |
| App bundle identifier | `uz.voicelab.desktop` |

The certificate/private key and notarization profile were verified on the original
release Mac. **Each additional Mac or CI runner must provision its own Keychain.**
Cloning this repository does not install either credential.

The Xcode project and release configuration both use team `FWCSVFT76D`. The
installed VoiceLab 1.3.1 app was checked on October 21, 2026: its bundle identifier
is `uz.voicelab.desktop` and its Developer ID designated requirement specifies
team `FWCSVFT76D`. Echo keeps its user-facing name and the `voicelab://` login
callback while adopting that existing application identity.

### Replacing the Electron app

This identity alignment prepares Echo to succeed VoiceLab. It does not implement
an Electron updater transition or import the Electron database, recordings, or
saved login. The native app still uses its own `VoiceLabNative` storage directory
and `uz.voicelab.native` Keychain service. Keep these separate until an explicit
data migration is implemented and tested.

For the initial manual CDN installation:

1. Quit both apps and back up the existing app and its local data.
2. Remove only the old `VoiceLab.app` application bundle, then install `Echo.app`.
   The different filenames mean dragging Echo into Applications alone leaves both
   installed. Keep a single installed copy for this bundle ID and login URL scheme;
   do not delete the old user data as part of installation.
3. Sign in and verify account data, microphone, Accessibility, shortcuts, and login
   callbacks. Permission and Keychain continuity require testing with the final
   signed release; sharing a bundle ID alone does not guarantee them.
4. Verify a rollback with the backed-up app before retiring the previous release.

Use a release version higher than the latest published VoiceLab version. The
locally inspected previous app is 1.3.1; confirm the production version before
publishing. The 2.0.0 commands below are examples, not an automatic version choice.
Any legacy updater rollout needs separate compatibility testing and configuration.

## One-time signing setup

1. Confirm an active Apple Developer Program membership and access to the selected
   publishing team, `FWCSVFT76D`.
2. Obtain the existing **Developer ID Application** identity as an encrypted `.p12`
   through the team's approved secret manager or secure transfer, then import it
   into your login Keychain using Keychain Access. Obtain its password separately.
   If a replacement identity is required, have the Account Holder create it in
   Xcode or Apple Developer → Certificates, Identifiers & Profiles. For a manual
   request, create the CSR using Keychain Access, upload it, and install the returned
   certificate on the Mac that generated the private key. Update the shared
   fingerprint and local configuration if the release certificate is replaced.
3. In Keychain Access → My Certificates, confirm that the certificate expands to
   show its private key. Back up the identity as an encrypted `.p12` in your team's
   secret store. A `.cer` file alone is insufficient on another build machine.
4. Unlock the signing Keychain and ensure it is in the user's Keychain search
   list. Find the certificate's 40-character SHA-1:

   ```sh
   security find-identity -v -p codesigning
   ```

   Choose the `Developer ID Application: ... (TEAM_ID)` entry. The fingerprint
   selects a specific certificate; it is not a secret. Apple Development and
   Apple Distribution identities are not accepted by this workflow.
5. Configure notarization using either of the following methods. Credentials stay
   in Keychain, outside the repository and command history. The existing team API
   key is the configured route; authorized release developers can obtain its `.p8`
   file through the team's secret manager and store it outside the checkout.

For an Apple Account, create an app-specific password at Apple's account site,
then run this command and enter that password at the secure prompt:

```sh
xcrun notarytool store-credentials "echo-notary" \
  --apple-id "RELEASE_ACCOUNT_EMAIL" \
  --team-id "FWCSVFT76D"
```

For the existing team App Store Connect API key (replace only the local file path):

```sh
xcrun notarytool store-credentials "echo-notary" \
  --key "/secure/location/AuthKey_8VJWSFC9U4.p8" \
  --key-id "8VJWSFC9U4" \
  --issuer "d7b6dbe8-1f6c-4cca-b742-47302decdac3"
```

For an individual API key, omit `--issuer`. The API key authenticates notarization;
it does not replace the Developer ID signing identity. For a custom CI Keychain,
add `--keychain /secure/location/release.keychain-db` when storing credentials and
set `ECHO_NOTARY_KEYCHAIN` to that same path. Provision/import/unlock CI signing
identities through the runner's secret management; these scripts do not modify
Keychain trust, revoke certificates, or generate replacement certificates.

Never commit the `.p12`/`.p8` files, private keys, passwords, Keychain databases,
CDN tokens, or `Configuration/release.env.local`. Keep these in the team's secret
manager or CI secret store. The API key ID and Issuer ID above identify the key;
the private `.p8` contents are the secret. Do not put secrets in GitHub issues,
pull request comments, or release attachments.

The DMG workflow needs no Developer ID Installer certificate. The app's current
unrestricted entitlements do not require a Developer ID provisioning profile.
Revisit export provisioning if restricted capabilities are added later.

References: [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/),
[creating a CSR](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request),
[notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
[Mac provisioning profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

## Local configuration

From the repository root:

```sh
cp Configuration/release.env.example Configuration/release.env.local
```

Edit the local file, then load it into your shell:

```sh
set -a
source Configuration/release.env.local
set +a
./scripts/release.sh check
```

The local file is gitignored. It contains shell syntax; load only a file you trust.
For CI, set the same environment variables directly instead of sourcing a file.

| Variable | Required | Value |
|---|---|---|
| `ECHO_TEAM_ID` | Yes | Confirmed 10-character Apple Team ID |
| `ECHO_SIGNING_IDENTITY` | Yes | 40-character SHA-1 of the installed Developer ID Application certificate with its private key |
| `ECHO_NOTARY_PROFILE` | For `all` / `notarize` | Stored `notarytool` profile name, normally `echo-notary` |
| `ECHO_NOTARY_KEYCHAIN` | No | Custom Keychain path containing that notarization profile |
| `ECHO_NOTARY_TIMEOUT` | No | Wait duration; defaults to `30m` |
| `ECHO_PUSH_ENABLED` | No | `1` requires a validated production APNs profile; default `0` keeps non-push packaging |
| `ECHO_PUSH_PROFILE` | When push enabled | Absolute path to the Developer ID provisioning profile outside this checkout |
| `ECHO_ARCHS` | No | `arm64 x86_64` universal; single-architecture update releases are rejected |
| `ECHO_UPDATE_HOST_MODE` | No | `cdn` by default; set `github` for the dedicated public artifacts repository |
| `ECHO_UPDATE_CHANNEL` | Yes | `stable`, `beta`, or `test`; baked into the app |
| `ECHO_UPDATE_FEED_URL` | Yes | Public HTTPS URL ending in `/CHANNEL/appcast.xml` |
| `ECHO_UPDATE_RELEASE_BASE_URL` | Yes | Immutable artifact root; CDN mode requires the same hostname, GitHub mode requires the dedicated release-asset URL |
| `ECHO_SPARKLE_PUBLIC_KEY` | Yes | Base64 32-byte Ed25519 public key embedded in the app |
| `ECHO_PREVIOUS_BUILD` | stable/beta | Highest build ever published across all channels; `0` only before the first release |
| `ECHO_ALLOW_DIRTY_TEST` | No | `1` permits dirty source only on `test`; default `0` |
| `ECHO_SPARKLE_TOOLS_DIR` | For feed preparation | `bin/` from pinned Sparkle 2.10.1 distribution |
| `ECHO_SPARKLE_KEY_ACCOUNT` | No | Sparkle signing Keychain account; default `uz.voicelab.echo.updates` |

`check` is local: it checks tools and signing identity availability, not Apple
service connectivity or notarization authentication. `store-credentials` validates
authentication when the profile is created. Full Xcode is required; select the
intended installation with `DEVELOPER_DIR` if multiple versions are installed.

## Xcode development signing troubleshooting

An error mentioning `com.screensaver.Voicelab`, a personal team, and unsupported
Push Notifications refers to older or locally overridden signing settings. Echo's
default entitlements file contains only microphone access. APNs is an explicit
release option; see [push packaging](../Configuration/PUSH_NOTIFICATIONS.md).

1. Update to the identity-alignment change and reopen `Voicelab.xcodeproj`. In the
   **Voicelab target → Signing & Capabilities**, check both Debug and Release:
   bundle ID `uz.voicelab.desktop`, team `FWCSVFT76D`, and automatic signing enabled.
   For local Run/Debug, use an Apple Development identity.
2. For ordinary Debug builds, use `Configuration/Voicelab.entitlements` and no
   push profile. Do not enable APNs to resolve an unrelated development-signing
   error. Push-enabled releases intentionally select `Voicelab-Push.entitlements`
   and a validated external Developer ID profile through the release script.
3. Team `FWCSVFT76D` currently has an Individual membership. An App Store Connect
   invitation, even with the Admin role, does not grant access to this signing team.
   Follow [Apple team access](APPLE_TEAM_ACCESS.md) for local development signing,
   organization conversion, and provisioning an authorized release Mac. Do not
   share the Account Holder's Apple Account password.
4. Use **Product → Clean Build Folder**, then build again. If the error still names
   the old bundle ID, check which project checkout Xcode has open and whether local
   target/build-setting overrides are replacing the checked-in configuration.

The CDN release script separately selects the Developer ID identity. A successful
release build does not by itself verify automatic development signing, so verify
the normal Xcode Build/Run configuration as well.

Reference: [Apple's macOS APNs entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment).

## Push-enabled releases

Set `ECHO_PUSH_ENABLED=1` and `ECHO_PUSH_PROFILE` to the external profile path.
`check` validates Apple's CMS signature/trust, exact team/app/certificate,
production APNs and profile validity. `build` snapshots and installs those exact
bytes in Xcode's user profile directory; export explicitly selects its UUID.
Archive, export, notarization and DMG verification reject missing/changed
profiles or an absent production APS entitlement. This configuration is recorded
with the archive and cannot change on resume. The default is still non-push;
providing a profile without explicitly enabling push is an error.

See [native notifications](../Configuration/PUSH_NOTIFICATIONS.md) for Apple
setup, backend deployment order, category preferences and signed-device tests.
Profiles are ignored by Git and must stay outside the source checkout. Never
copy the APNs backend private key into an app or release artifact.

## Build a release

Run the app and release regression tests first. Stable/beta require a clean source
checkout. Build numbers are positive, globally increasing integers and must never
reset when the marketing version changes. Set `ECHO_PREVIOUS_BUILD` to the highest
published build across all channels. The examples below assume that value is 41;
confirm the actual production value before choosing the next number.

```sh
./scripts/release.sh all 2.0.0 42
```

Or run `build`, `sign`, `notarize`, and `package` individually with the same version
and build. Settings are injected into this archive without editing the project.
The saved source record binds resumed stages to the same channel, feed URL, public
key and artifact URL root. Never relabel a test app as stable: its embedded feed is
different. A stable app can be tested against an unpublished release before feed
promotion, or build an isolated test-channel app with a distinct build number.

For local test builds, explicitly use `ECHO_UPDATE_CHANNEL=test`, a feed ending in
`/test/appcast.xml`, and (only if necessary) `ECHO_ALLOW_DIRTY_TEST=1`. Test artifact
names end in `-test`; beta names end in `-beta`. Production source must be clean.

1. **Build/export:** Archive a universal Release app with Developer ID, hardened
   runtime and secure timestamps. Verify the outer app plus every nested Mach-O,
   including WakeHelper, Sparkle, Autoupdate, Updater and both XPC services. Reject
   missing components, wrong teams, debug entitlements, wrong architectures,
   escaping/broken symlinks, wrong updater keys/URLs and framework version drift.
   The archive stage checks nested structure, signatures and architectures; Xcode
   export re-signs original Sparkle helpers. Full team/runtime/timestamp validation
   applies to the exported app and final DMG. Framework code itself need not have
   the process runtime flag; helper processes do.
2. **Notarize app:** Submit a ZIP of the exported app, persist the submission ID
   and checksum, wait for acceptance, then staple and assess the app.
3. **Notarize DMG:** Stage outside the build tree in system temporary storage to
   avoid source-volume busy errors. Create an HFS+/LZFSE disk image containing
   the stapled app, Applications link and [guided Finder layout](INSTALLER_PACKAGING.md).
   Verify its background and auto-open metadata after remounting, sign the DMG with Developer ID, copy it
   into same-filesystem staging and atomically promote it for separate submission.
   Preserve the submitted DMG untouched. Staple a copy after acceptance.
4. **Package:** Validate both staples, Gatekeeper and the DMG signature; mount it
   read-only and verify the contained app again. Compute hashes from final bytes.
   Atomically expose the output directory only after all checks pass.

```text
build/releases/Echo-2.0.0-42-universal/    # Private: never publish this directory
  Echo.xcarchive/                         # Includes dSYMs
  export/Echo.app/
  source.plist / archive.log / export.log
  notary-upload.zip / notary-upload.sha256
  notary-submission.json / notary-result.json / notary-log.json
  dmg-upload.dmg / dmg-upload.sha256
  dmg-submission.json / dmg-result.json / dmg-log.json
  Echo.dmg                               # Final stapled copy

dist/Echo-2.0.0-42-universal/
  Echo-2.0.0-42-universal.dmg
  SHA256SUMS.txt
  release.json
```

Metadata includes source commit/dirty status, version/build, bundle/team identity,
architectures, minimum OS, both notarization IDs, channel/feed/public key, Sparkle
version and final DMG byte count/SHA-256. Metadata is not an update feed.

## Resume and failures

- After an Apple timeout or interrupted wait, rerun **notarize** with the exact
  same configuration/version/build. Saved accepted submissions are reused; pending
  submissions resume. Neither app nor DMG is resubmitted blindly.
- After an unknown submit outcome, inspect `notarytool history`/`info` with the
  same Keychain profile. Match upload name/time and recover the response into
  `notary-submission.json` (app) or `dmg-submission.json` (DMG). Keep the original
  upload and its checksum. A missing/invalid response blocks further submission.
- `Invalid`/`Rejected`, signature errors, missing staples or Gatekeeper errors
  block packaging. Inspect the matching logs and use a new build after a fix.
- App ZIP and DMG creation use fresh temporary staging directories and atomically
  move only completed files into submission paths. An interrupted/signing-failed
  packaging attempt can be retried without reusing a partial archive. After a
  forced kill, obsolete temporary directories may remain for manual cleanup;
  resumed work does not reuse them. Never alter `dmg-upload.dmg` after submit.
- An existing output directory is never overwritten. A per-release lock prevents
  concurrent runs. After a forced termination remove its empty `.lock` only after
  confirming that release process is gone. Failed image unmounts are left intact
  for manual cleanup rather than deleting through a mounted filesystem.
- Do not bypass Gatekeeper, strip quarantine, force-sign nested code, or reuse a
  released build number to make a failure disappear.

## Pin the Sparkle signing tools

The app dependency and release tooling both use **Sparkle 2.10.1**. Use the tools
already downloaded by Xcode at
`SourcePackages/artifacts/sparkle/Sparkle/bin`, or download the official artifact:

```sh
curl --fail --location --proto '=https' --tlsv1.2 \
  https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip \
  -o /tmp/Sparkle-2.10.1.zip
printf '%s  %s\n' \
  4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a \
  /tmp/Sparkle-2.10.1.zip | shasum -a 256 -c -
mkdir -p build/tools/Sparkle-2.10.1
ditto -x -k /tmp/Sparkle-2.10.1.zip build/tools/Sparkle-2.10.1
export ECHO_SPARKLE_TOOLS_DIR="$PWD/build/tools/Sparkle-2.10.1/bin"
```

The feed tool independently pins `sign_update` SHA-256 to
`43c249771bafc3aa581228abae00731a012d324691b8292860896635050be76b`.
Changing the Sparkle version requires reviewing/updating both pins and tests.
The dedicated Sparkle signing key was provisioned with the official tool in the
release Mac's Keychain, account `uz.voicelab.echo.updates`. Its public key is
`XzFmEWjxWA+1rQc1mHl1tokbcYSWaSJMcCvFEOLwLHc=`. These are safe public settings;
the private key is never part of the app or repository. Provision other release
runners separately; these scripts never create/export keys.

**Keep a verified encrypted recovery backup in the team's secret store before
production rollout.** On October 29, 2026, an AES-256 recovery disk image was
created using a password entered directly by the release owner. Export occurred
only inside that encrypted volume; reopening it read-only verified the recovered
key against the published public key and a fresh signing challenge. The encrypted
file was handed to the owner for off-device storage; that upload is owner-managed.
No private material or password is stored in this repository. The embedded public
key must match the selected Keychain account. Signing with
another key fails public-key verification before any publication directory appears.

## Prepare the signed feed

The app requires signatures for archives, feeds and release notes, and verifies
archives before extraction. Feed-signature failure expiration is set to `0`:
invalid signatures remain blocked, without Sparkle's default 20-day fallback.
System profiling and JavaScript in release notes are disabled and validated.
A Developer ID-signed DMG retains Sparkle's supported
key-rotation recovery path; a ZIP cannot provide that path with verification before
extraction. Apple code signing and Sparkle Ed25519 signing are separate layers.

Write reviewed HTML release notes (no scripts), then prepare locally:

```sh
python3 scripts/update_release.py prepare dist/Echo-2.0.0-42-universal \
  --notes release-notes.html --output dist/publication-42 \
  --previous-feed /path/to/exact-current-appcast.xml
```

For a channel's **first** feed only, use `--initial-feed` instead. The publisher
must enforce that the feed does not already exist. For subsequent releases supply
the exact current signed feed; its signature and channel are verified, and the
new build must be higher than every item. Preparation keeps the newest three
stable items or one test/beta item by numeric build number. It refuses trimming
that would lose an older macOS compatibility floor or unsupported selectors/delta
dependencies; `--keep-releases` can explicitly retain additional history. Existing
signed feeds are unchanged until a new feed is prepared, signed and published.

After every fully verified GitHub publication, the checked-in retention policy
keeps at least three stable/one test/one beta installers, every signed-feed and
website current/fallback reference, and a 24-hour grace period. Cleanup safely
defers when website protection or public CDN verification is unavailable, without
failing the successful publication. It archives lightweight provenance before any
whole-release deletion. See [release retention](RELEASE_RETENTION.md) for exact
plan review, operator recovery, and the explicit `--skip-retention` override.

`sign_update` signs the final stapled DMG and notes; the script constructs XML,
signs it last and verifies all signatures against the embedded public key using
CryptoKit. No XML/HTML formatting, minification or header injection is allowed
after signing. Release notes and appcast must be served byte-for-byte unchanged.
The default phased interval is 86400 seconds between Sparkle's seven cohorts;
`--phased-interval 0` disables it. Manual checks bypass phasing, so it is not a
strict percentage rollout or an emergency kill switch.

Prepared directory layout:

```text
dist/publication-42/
  publication.json
  releases/stable/2.0.0/42/
    Echo-2.0.0-42-universal.dmg
    release-notes.html
    SHA256SUMS.txt
    release.json
  stable/appcast.xml
```

The JSON plan lists exact public URLs, local relative paths, hashes, byte counts,
content types and cache policies. Immutable entries precede the mutable feed.
It includes the previous feed SHA-256 for conditional promotion, or an explicit
`feedMustNotExist` bootstrap precondition. It is a publisher input, not permission
to overwrite objects. The generic CDN tooling intentionally has **no CDN write command**. The separate
GitHub publisher consumes this plan for the selected managed hosting option.

## Managed GitHub hosting (selected deployment option)

The public **artifacts-only** repository is `voicelab-uz/echo-releases`. The Echo
source repository remains private. Use GitHub Releases for signed DMGs/notes and
the dedicated repository's `main` branch only for signed feed files. Never publish
source archives, private build logs, dSYMs, signing material or configuration files
as release assets. GitHub's automatic source archives contain only the contents of
this artifacts repository, not the private application repository.

```sh
export ECHO_UPDATE_HOST_MODE=github
export ECHO_UPDATE_CHANNEL=test
export ECHO_UPDATE_FEED_URL=https://raw.githubusercontent.com/voicelab-uz/echo-releases/main/test/appcast.xml
export ECHO_UPDATE_RELEASE_BASE_URL=https://github.com/voicelab-uz/echo-releases/releases/download
```

Set the channel/feed to `stable` for production. The tool deliberately accepts only
these exact dedicated-repository routes in GitHub mode; it cannot target the
private app repository accidentally. Use immutable tags `CHANNEL-VERSION-BUILD`,
for example `test-2.0.0-102`. The corresponding artifact URL is
`https://github.com/voicelab-uz/echo-releases/releases/download/test-2.0.0-102/Echo-2.0.0-102-universal-test.dmg`.
Local preparation uses `releases/test-2.0.0-102/` in its publication directory.

Before publishing, provision the public repository, enable immutable Releases,
and grant a narrowly scoped publisher role. A draft release is populated and
verified before publication; once published its assets/tag must remain immutable.
The feed branch is a separate mutable pointer. The publisher must compare the
currently published signed feed with the preparation snapshot and atomically
advance the branch without force-pushing over concurrent updates.

`publication.json` includes `hostMode`, `repository`, `releaseTag`,
`artifactVersionedPath`, `version`, `build`, `sourceCommit`, `sourceDirty`, `teamID`,
`feedMustNotExist`, `previousFeedSHA256` and the ordered files. Only the files
explicitly listed as immutable become release assets; the signed appcast is
promoted after those assets pass public verification. Stable/beta builds require
clean source. The explicit `test` channel permits dirty test artifacts; it cannot
promote those artifacts into stable/beta.

The separate `scripts/publish_github.py` validates then publishes the prepared
plan. Read `--help` before running it; an invocation can create a public release
and advance the feed. Stable/beta requires the explicit `--promote` option.
GitHub authentication belongs to the publisher, not Echo's updater. For example:

```sh
python3 scripts/publish_github.py dist/publication-102
# For a separately prepared clean stable/beta publication:
python3 scripts/publish_github.py dist/publication-103 --promote
```

Clients fetch feeds and binaries anonymously. `verify-public` supports up to five
HTTPS GET redirects limited to GitHub's release asset hosts, validates exact
public bytes, and probes DMG byte-range responses. Redirects outside the allowlist
or to HTTP fail. It never forwards publisher credentials to asset URLs.

GitHub controls raw-feed caching and release-asset content types, so its mode does
not pretend to enforce the custom CDN cache headers. It accepts GitHub's normal
raw XML/text and download MIME types while retaining size/hash/signature checks.
A feed promotion can take time to reach all edge caches. Verify anonymously and
wait/retry stale caches before declaring rollout success. Publisher exit code `2` means the
feed commit is confirmed but public cache verification is pending; rerun the same
publication to reconcile without republishing. Do not mutate or append
cache-busting parameters to already signed feed data or artifact URLs.

The operational release gate is an actual public N→N+1 update test. Repository
creation and draft asset upload alone do not prove that automatic updates work.

## Self-hosted CDN contract (available alternative)

`cdn.aisha.group` is the confirmed existing hostname. The proposed dedicated bucket
is `voicelab-echo-releases`. Echo's bucket, namespace,
origin mapping and scoped publisher credentials have not yet been provisioned or
verified. The example `/voicelab-echo-releases/macos/...` URLs are a proposed contract, not working
production endpoints. The infrastructure owner must configure:

- Public direct HTTPS GET/HEAD for feeds, notes and DMGs; no login, expiring links,
  redirects, HTML error pages or middleware rewriting signed XML/HTML. Support
  `Content-Length`, byte ranges, ETags and normal download cancellation/resumption.
- Immutable objects at `/voicelab-echo-releases/macos/releases/CHANNEL/VERSION/BUILD/...` with
  `Cache-Control: public, max-age=31536000, immutable`; fail conditional creation
  when an object already exists with different bytes. Idempotent retries must
  verify matching bytes, never silently replace a version.
- Feeds at `/voicelab-echo-releases/macos/CHANNEL/appcast.xml` with
  `Cache-Control: public, max-age=60, must-revalidate, no-transform`. Revalidate
  quickly and avoid long negative caching when bootstrapping a feed. Retain prior
  feed versions and serialize publisher promotions per channel.
- A scoped upload role limited to Echo paths; private signing keys stay on the
  release Mac/CI. The public update path must work independently of the Go API.

Publishing order is a required transaction boundary:

1. Reserve a globally increasing build number; build and test from clean source.
2. Prepare signed artifacts/feed using the currently published feed snapshot.
3. Conditionally create immutable release objects first. Interrupted uploads must
   not expose partial objects; use object-store completion or same-filesystem
   temporary-file-plus-rename on a file server.
4. Verify through the **public CDN**, against the local prepared bytes:

   ```sh
   python3 scripts/update_release.py verify-public dist/publication-42
   ```

5. Promote the feed only after every immutable object passes. In one serialized
   origin operation, compare the current feed hash with `previousFeedSHA256`
   (or assert absence), then atomically replace/create the feed. A separate
   check-then-PUT is racy; use an object ETag/If-Match condition tied to the checked
   snapshot, or an origin lock plus atomic rename. On conflict fetch the new feed,
   regenerate/re-sign, and retry. Never overwrite a concurrent release.
6. Purge/revalidate only the channel feed if needed, then verify:

   ```sh
   python3 scripts/update_release.py verify-public dist/publication-42 --include-feed
   ```

7. Publish the website download link only after browser-install and updater smoke
   tests pass. Keep the prior artifacts and signed feed for recovery.

An uploader adapter should be implemented only after the actual origin and
conditional-write contract are confirmed; guessing an S3 bucket or using the
existing authenticated media-upload API would weaken these guarantees.

## Release validation and recovery

Test the final Developer ID build on Apple Silicon and Intel, on the minimum and
current macOS versions. Browser-download the DMG to exercise quarantine, mount it,
move Echo to Applications, and launch without bypassing Gatekeeper. Test account
continuity, onboarding resume, microphone/Accessibility denial and grant, Fn,
recording/transcription, insertion, login item and restart. Sparkle's helper
processes and WakeHelper must retain the same team across upgrades.

Test N→N+1 with the actual public CDN: manual update, automatic download, installation
on quit, busy-session deferral, cancel, lost network, corrupted/truncated archive,
invalid signatures, stale feed, insufficient disk, read-only install location,
app quit/crash during download, wake-helper behavior and successful relaunch.
Power loss/process termination during replacement needs a dedicated test machine;
unit tests and notarization do not prove crash-free behavior.

To stop offering a bad release, restore or regenerate a signed feed without that
item and atomically promote it under the same concurrency rules. Already-downloaded
updates may still install; withdrawing a feed is not remote rollback. Ship the fix
with a **higher build number**. Do not make clients downgrade data schemas. Retain
backward-compatible migrations and an operator-tested manual recovery path.

Key rotation is a separate reviewed release: follow Sparkle's rotation procedure,
retain the old keys for a bridge release, and never change the Developer ID identity
and Ed25519 key simultaneously. With fail-closed feeds, losing the old Ed25519
key cannot be repaired by a signed DMG alone: clients reject the feed first.
Recover the old key from backup or use an explicit manual reinstall/recovery path.
This preparation command deliberately rejects a
previous feed signed by a different key; it does not automate exceptional rotation.

Keep archives, dSYMs, logs, source commit, build settings and publication plans in
private release storage. Separate the signing job from the CDN publisher. Do not
log/export private keys, notarization credentials or CDN tokens.

```sh
./scripts/test-release.sh
```

The regression harness uses fake Apple services and DMG mounting with real
plist/ZIP/checksum tools. It covers interrupted app/DMG notarization, unknown
submission outcomes, final-byte binding, nested helper trust, clean-source/build
policies, feed ordering/channel isolation, malformed/tampered feeds and wrong-key
failure cleanup. CryptoKit verification is checked with an RFC 8032 public test
vector; no private key is generated/read. These tests do not replace the real
installation/update matrix above.

References: [Sparkle publishing](https://sparkle-project.org/documentation/publishing/),
[Sparkle security settings](https://sparkle-project.org/documentation/customization/),
[signing and key rotation](https://sparkle-project.org/documentation/),
[pinned 2.10.1 package](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Package.swift).
