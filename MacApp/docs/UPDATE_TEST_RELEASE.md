# Echo automatic updates — test release

October 29, 2026. Sparkle 2.10.1 is integrated into the native Echo app. GitHub Releases hosts downloads in the dedicated public [echo-releases repository](https://github.com/voicelab-uz/echo-releases); the application source repository remains private. This page retains test-channel qualification evidence. Stable build 108 is now published; see [the stable release record](STABLE_RELEASE_108.md).

Build **107** is the latest verified test release. It uses the same app source and installer as build 106 and was published specifically to qualify installation on ordinary quit. It includes the final installer design: four Echo mascot poses, the native Echo disk icon, one drag-to-install instruction, and a small, separate VoiceLab maker credit using the supplied logo artwork. Builds 104–107 were produced from clean, committed source.

## Try the upgrade

1. Quit the currently installed Echo after finishing any recording.
2. Download [test build 106](https://github.com/voicelab-uz/echo-releases/releases/download/test-2.0.0-106/Echo-2.0.0-106-universal-test.dmg), open the DMG, and copy Echo into Applications.
3. Open Echo from Applications, then choose **Check for updates…** from its menu. Install the available update and allow Echo to relaunch.
4. Confirm build **107** in **About Echo**. Check that onboarding/account state, notes, microphone selection, Fn dictation, and Accessibility text insertion still work.
5. Also check automatic download in Settings, then quit while idle and verify that the update installs. Use a fresh copy of build 106 for a separate automatic-update test.

These are universal downloads for compatible Apple Silicon and Intel Macs running macOS 14 or newer. The previous installed development app used a different signing team; macOS permission and Keychain continuity must be checked during this first transition. Do not test by replacing an app while it is recording.

## Implemented behavior

- Native Settings and menu-bar update actions; automatic checks/downloads can be disabled. Scheduled update notices remain quiet.
- Signed feeds and release notes, Ed25519-signed archives, Developer ID signing, hardened runtime, notarization and stapled app/DMG tickets.
- Restart gating for recordings, retryable audio, sign-in, text insertion, setup activity, pending saves and unsaved editor drafts. Credentials and encrypted local state are flushed before installation.
- Canceled preparation restores services; late callbacks cannot unlock a different installation. Staged updates persist across app restarts, and Skip clears the staged state.
- The login helper pauses during installation using a bounded lease. Onboarding practice text is checkpointed in encrypted, account-scoped storage.
- GitHub publication stages a draft, checks asset hashes, locks the published release, verifies public bytes, and updates the signed feed last with a compare-and-swap. Stable/beta promotion requires a clean source tree and an explicit promotion command.

Update delivery uses the signed feed and release assets independently of the application APIs. The updater does not send audio, transcript contents, account identifiers or tokens as telemetry.

Related application changes are already deployed to production:

- Frontend authentication: `8b43757433d5c31bc2dcb1b954eb5d997461d053`, workflow run `40763935054`, release `ci-8b43757433d5-40763935054-1`.
- Frontend desktop-consent branding: `3df2ca3c110ba2b304f978e5cf44d8cccdd40ca9`, workflow run `40770204737`, release `ci-3df2ca3c110b-40770204737-1`. The current production consent screen identifies Echo; ordinary VoiceLab account branding remains unchanged.
- Backend: `c48b1b66bf3b11e68eb30fb1a1878a0647f7885f`, workflow run `40762039903`.

Production health checks and the frontend’s new deployment identifier were verified. Both the existing-session browser consent/API/loopback flow and a fresh Google-provider sign-in passed.

## Validation completed

- Universal archive/export for builds 102–107; every nested executable inspected for architecture, signature, team and release entitlements.
- Apple accepted the apps and disk images for builds 102–107. Stapler, strict signature verification and Gatekeeper checks passed, including the app mounted from the final DMG.
- Configuration validation, authentication (58 tests), restart/cancellation, helper lease, encrypted draft restoration, notes/outbox synchronization, onboarding, Try It, session routing, usage accounting and pending-save quit regressions passed.
- Release interruption/retry tests, signed-feed/tamper checks and mocked GitHub publication/conflict tests passed. Tests cover ambiguous remote responses and GitHub's temporary draft URLs.
- Update Settings was rendered in light/dark and error states using the real SwiftUI component in an isolated host.
- Public bytes and DMG range responses were verified for builds 102–107. These GitHub releases are published, immutable prereleases with exactly the expected four assets. The signed test feed points to build 107 and retains builds 102–106; at that point no stable feed had been published. Stable build 108 was published subsequently, as recorded separately. Initial raw-CDN cache delays for 104–107 were reconciled by re-running the same prepared publication after propagation, without rebuilding or replacing assets.
- The installer was verified in real Finder: its layout applies, the draggable items remain native, and Echo’s logo appears on the mounted disk and in Finder’s titlebar. Four native scratch-image tests verify icon persistence through compression/remount, unchanged app files, preserved unrelated Finder flags, and rejection of invalid paths/metadata. The 24 release workflow tests passed, including failure before publication if remounted icon verification fails.
- An isolated client using the actual Sparkle framework accepted the signed public feed and selected build 103 while reporting installed build 102, without installing anything. Its disposable unsigned host emitted a sandbox-extension warning, but the completed Sparkle probe returned success; this is not evidence about installation-helper behavior in the signed Echo app.

On October 29, a real Chrome download of build 102 retained quarantine and matched the published checksum. Finder drag-install, the normal Gatekeeper Open prompt and first launch succeeded. macOS required user authentication to migrate Keychain access from the old development signing team; the user approved it. The real Sparkle **102 → 103 installation and relaunch passed**, preserving the account and local history with no second Keychain prompt. The installed build and deep signature were verified. Accessibility became effective after an ordinary quit/reopen, and onboarding resumed on the same step with microphone and Accessibility allowed. The user subsequently reached the signed-in workspace; the exact physical microphone/Fn results were not separately confirmed.

The run exposed a misleading startup update error while Keychain restoration was pending, a Sign Out button labeled Quit, and untranslated microphone permission text. Build 104 includes those fixes, localized browser callback pages, and unsaved-editor restart protection.

For **103 → 104**, the updated installed build and running app were confirmed after relaunch. The user operated Sparkle while other work continued, so the complete sequence of installer clicks was not witnessed. The main window was closed; reopening Echo restored a healthy UI. This was a recoverable window state, not evidence that the app had failed to launch. The separate sign-in and ordinary-quit installation tests are documented below.

On installed **104**, a live browser SSO round trip passed: sign-out was confirmed, Echo opened the existing authenticated browser session’s consent page, the current Echo request was approved, the app returned to its signed-in workspace/account, and the callback tab closed. This verifies the deployed consent, API and loopback path. It does not verify a fresh Google-provider login because the browser was already authenticated.

For **104 → 106**, the user confirmed selecting **Install and Relaunch**. The installed build, deep signature, both binary architectures and restored signed-in workspace were verified. This confirms the manual installation path; it is not the automatic-quit test.

On installed **106**, a fresh Google-provider sign-in passed. The VoiceLab browser session and Echo session were signed out, Echo started a new browser authorization, the Google account chooser was used, the updated **Sign in to Echo / Continue to Echo** consent was approved, and Echo returned to the signed-in workspace. The callback tab closed. An earlier attempt expired while test tooling was being adjusted; a new request completed successfully through the normal retry path. Passwords, session cookies and tokens were not inspected.

The **106 → 107 ordinary-Quit installation passed**. The update was downloaded through Check for Updates and reached Ready to Install. Install and Relaunch was not selected. A normal application termination request closed idle Echo; the installed bundle advanced to 107 without relaunching itself. Echo then reopened normally with the signed-in account/workspace intact and no additional Keychain prompt. Strict deep code-signature verification passed, and the executable contains both `x86_64` and `arm64`. This verifies installing a staged update on normal quit; it does not claim the hourly background scheduler was observed firing.

On installed **107**, the user confirmed the real hardware flow: focus a text field, press physical Fn/Globe, speak, press again, and receive the inserted text. This verifies shortcut, recording, transcription and Accessibility text insertion on this release.

Physical Intel and oldest-supported-macOS coverage, low disk space, denied installation authorization and force-quit during replacement remain release qualification tasks. No automatic rollback after a faulty app launch is claimed.

## Release identities and artifacts

| Build | DMG SHA-256 | App notarization | DMG notarization |
| --- | --- | --- | --- |
| 102 | `7d71b60178fccd0eebb07cff5a755f6320699b0b458c0bd9cc2e8f50e303f1a7` | `1153daa3-00ae-41b7-a912-af28e7bcab8b` | `55103a98-d71b-40bc-b798-9f7e61d2aeb9` |
| 103 | `64c2d53109358bf2394ef242f94b052b076c9b28f0a10a1c09757a52ffcc0cda` | `d54b5d70-b79e-496c-be11-b0cd9cdb8429` | `b1a7c45f-1c71-4683-bdd7-5ffd338702b2` |
| [104](https://github.com/voicelab-uz/echo-releases/releases/download/test-2.0.0-104/Echo-2.0.0-104-universal-test.dmg) | `2e92b6ce7e13d42c244c738bf12150e10819230d4b4ec80935610c1c7bed037f` | `33d3f1fa-2bcb-4264-bc62-9117a43f2286` | `a2d2bea3-fd2b-491f-b641-63abbc797c9b` |
| [105](https://github.com/voicelab-uz/echo-releases/releases/download/test-2.0.0-105/Echo-2.0.0-105-universal-test.dmg) | `b9a145cd18e9a47c081045142d58138c84463418a2f8fa19ecee6832c275d287` | `f16f283f-bd7e-428c-ba6f-40743282212e` | `5c8f22a4-606d-480d-814e-e1dc5b83d793` |
| [106](https://github.com/voicelab-uz/echo-releases/releases/download/test-2.0.0-106/Echo-2.0.0-106-universal-test.dmg) | `4107bf7c5fbc13e79ffc6bc8465324f05f8a1f16c1b8385f0517399a2858fd1a` | `72bbf81a-5996-47b1-98bb-128d09f4b052` | `6957dfcb-f255-42d6-b6a6-52c90c734d43` |
| [107](https://github.com/voicelab-uz/echo-releases/releases/download/test-2.0.0-107/Echo-2.0.0-107-universal-test.dmg) | `57048708df8def60ffa6e8529ffafba88201ddebd32b87bb76f3c179fa149c5b` | `e56df563-9f01-4406-818f-9df4da927f1a` | `64e26857-c341-4189-b165-efc7b91dc884` |

Publishing team: `FWCSVFT76D`. App ID: `uz.voicelab.desktop`. Sparkle public key: `XzFmEWjxWA+1rQc1mHl1tokbcYSWaSJMcCvFEOLwLHc=`. The working private key remains in macOS Keychain under account `uz.voicelab.echo.updates`. On October 29, the release owner chose a password in a secure local dialog and an AES-256 encrypted recovery disk image was created outside the repository. Export occurred only inside the encrypted volume. The image was detached, reopened read-only and verified against the published public key using a fresh signature challenge; the original Keychain was unchanged. The encrypted file was handed to the owner for off-device vault storage, which the owner must complete. No password or private-key contents were logged or committed.

Builds 102 and 103 explicitly record `sourceDirty: true` against commit `27ce5e2`, preserving the user’s then-uncommitted work. The newer test builds use clean source:

| Build | Source commit | sourceDirty |
| --- | --- | --- |
| 104 | `b7838ee7666f2aadeaecbf546b35a0406e33e898` | `false` |
| 105 | `28e6755832edfe4e24d3dc52c12df124cf5fb2ae` | `false` |
| 106 | `4c49d6fd832847327877b9f5bbbfcce4e9e9481b` | `false` |
| 107 | `4c49d6fd832847327877b9f5bbbfcce4e9e9481b` | `false` |

These artifacts embed the test feed and remain test releases. Create a fresh clean stable build with stable configuration only after the remaining test gates pass; do not relabel or promote a test DMG into a stable artifact.

## Repeatable commands

See [the release runbook](CDN_RELEASE.md) and `Configuration/release.env.example` for the non-secret settings and Keychain setup. The sequence is:

```sh
bash scripts/release.sh all VERSION BUILD
python3 scripts/update_release.py prepare dist/RELEASE --notes NOTES.html --output dist/PUBLICATION --previous-feed CURRENT-SIGNED-FEED.xml
python3 scripts/publish_github.py dist/PUBLICATION
python3 scripts/update_release.py verify-public dist/PUBLICATION --include-feed
```

For an opt-in live feed check, set `SPARKLE_FRAMEWORK_DIR`, `ECHO_UPDATE_FEED_URL`, `ECHO_SPARKLE_PUBLIC_KEY`, `ECHO_INSTALLED_PROBE_BUILD=106` and `ECHO_EXPECTED_UPDATE_BUILD=107`, then run `zsh scripts/test-live-update-feed.sh`. It creates a disposable app identity and performs only a probing update check.

The first feed uses `--initial-feed`; later publication always binds the exact prior signed feed. A publisher exit code 2 means the feed commit succeeded but the raw CDN cache still needs verification. Re-run the exact publication to reconcile; do not rebuild or overwrite its assets.

The Mac App Store edition is a separate effort because the current app uses capabilities incompatible with App Sandbox. See [Store readiness](APP_STORE_READINESS.md).
