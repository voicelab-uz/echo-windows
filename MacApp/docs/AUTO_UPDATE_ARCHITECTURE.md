# Echo macOS automatic updates — architecture proposal

Original audit: 2026-10-28 against Echo `27ce5e2` plus the existing local changes. The sections below preserve that architecture review. Implementation subsequently added Sparkle and test releases on GitHub's artifact CDN, which the user selected as an alternative to provisioning MinIO. See [implementation and test status](UPDATE_TEST_RELEASE.md) for completed checks and remaining release gates.

**Recommendation: Sparkle 2, public static update feeds on our CDN, and an Echo-owned coordinator that permits installation only when work is safely persisted.** Keep a signed manual installer available for recovery. Use the existing release driver as the foundation.

Three parallel audits covered updater alternatives, the app lifecycle, and publishing. The Main Agent chat was consulted for infrastructure context. Findings below distinguish existing behavior from proposed work.

“Never crashes” cannot be guaranteed by any framework. The engineering requirement should be that expected update failures do not terminate an active session, discard recordings, log users out, or leave an unusable installation. These are release acceptance criteria, not claims already verified.

| Approach | Advantages | Costs and limitations | Recommendation |
| --- | --- | --- | --- |
| Sparkle 2 + our CDN | Native macOS installation framework, standard UI, signatures, background delivery and rollout support | Requires lifecycle integration, correct release signing and continuing security maintenance | Best fit for native Echo |
| Squirrel.Mac + update service | Server-driven version selection; signed updates and a separate installer | More server logic, custom app UI and build dependencies | Viable alternative, particularly for an existing Electron distribution |
| Custom manifest, downloader and installer helper | Complete control of cohorts, protocol and UI | We own security, privileges, interruption recovery and every installation edge case | Avoid for the first implementation |
| Signed manual DMG | Straightforward installation and rescue path | Users must download and replace the app; adoption is slower | Keep alongside automatic updates |
| Mac App Store | Apple manages distribution and updates | Separate distribution, entitlement and review strategy; does not fulfill the own-CDN requirement | Separate product decision; TestFlight remains a testing channel |
| PKG/MDM deployment | Useful for managed enterprise Macs and system components | Requires management or an installer workflow; a package alone is not an updater | Optional enterprise distribution later |

Sparkle **2.10.1**, released October 25, is the current stable candidate, compatible with Echo’s macOS 14 minimum. It includes an installation-timing correction involving Unicode paths. Pin the tested version and tooling rather than allowing unreviewed dependency upgrades. [Official releases](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1)

Squirrel.Mac remains a credible alternative. Its current implementation describes resumed downloads, deltas and full-archive fallback, but requires application-owned UI and additional build dependencies. [Squirrel.Mac](https://github.com/Squirrel/Squirrel.Mac)

## What exists and what must change

| Finding | Evidence | Consequence |
| --- | --- | --- |
| Native updater is a placeholder | `Voicelab/Services/AppUpdateChecker.swift:3` opens TestFlight | Implement a real check/download/install integration |
| Quit protects only regular busy dictation | `Voicelab/VoicelabApp.swift:160` | Onboarding recording, microphone checks and sign-in can be interrupted |
| Failed audio can still be retryable | `Voicelab/Features/Dictation/DictationModel.swift:38` and `:204` | “Not busy” is insufficient; automatic exit must not discard recoverable audio |
| Shutdown stops services before all preparation succeeds | `Voicelab/App/AppModel.swift:559` | A failed flush can cancel exit after services have stopped; preparation needs cancellation recovery |
| Wake helper relaunches an absent app | `EchoWakeHelper/EchoWakeHelper.swift:29` | It can race with installer replacement unless coordinated |
| Strong local persistence foundations | `SecureStorage.swift:110`, `LibraryModel.swift:339`, `Authentication.swift:393`, `OnboardingJourney.swift:20` | Reuse atomic saves, durable queues and checkpoints; cover their error paths |
| Packaging already signs, notarizes, staples and validates | `scripts/release.sh:87`, `:153`, `:183` | Extend this pipeline instead of replacing it |
| No native signed feed or CDN publisher | `docs/CDN_RELEASE.md:289` | Add publication and verification, not just an app dependency |
| Production signing identity is inconsistent | Existing release docs: `FWCSVFT76D`; upstream Xcode: `L5FXR2YA4Q`; local override: `FWCSVFT76D` | Verify against actual distributed binaries and settle identity before shipping |

The bundle identifier is `uz.voicelab.desktop`. Matching only that string does not establish continuity of Accessibility permissions, Keychain access, helpers or notifications. Keep `Echo.app` and its production signing identity stable. Treat an intentional signing-team change as a tested migration.

Existing release checks explicitly inspect the outer application but need an inventory of nested components once Sparkle is embedded. Verify EchoWakeHelper, Sparkle executables and applicable services for expected identity, architecture, runtime, entitlements and signature validity. Preserve symlinks and executable permissions. Keep Xcode archive/export responsible for signing; do not repair an archive with indiscriminate recursive re-signing.

## Proposed user experience and lifecycle

The app checks quietly in the background. Settings offers “Check for Updates” and an automatic-update preference. A verified download produces a small “Update ready” indication with “Restart & Update” and “Later.” Automatic installation waits for a safe quit. Avoid taking focus during dictation or presenting repeated network-error dialogs. A manual check can show an actionable error.

Use one app-lifetime `SPUStandardUpdaterController`, with Sparkle’s standard installation and authorization UI. Echo supplies the subtle status presentation. [Programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/), [Gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/)

```mermaid
flowchart LR
    A[Signed CDN feed] --> B[Check and download]
    B --> C[Verify update]
    C --> D[Wait for safe quit]
    D --> E[Acquire restart barrier]
    E --> F[Persist state and coordinate helper]
    F --> G[Sparkle installation]
    G --> H[Relaunch and verify local state]
```

The proposed `UpdateReadinessCoordinator` tracks activity leases instead of guessing readiness from the visible screen. It covers regular dictation, retryable recordings, onboarding trial and microphone tests, permission/key validation, browser authentication, credential persistence, local saves and future meeting capture.

At restart, acquire an exclusive barrier and recheck readiness. New recordings and credential exchanges cannot begin after that check. Flush local notes and the durable sync queue; completing a server sync is not required, so offline users can still update. Preserve refresh-token recovery state and refuse automatic exit while the only valid credentials exist solely in memory.

Separate reversible preparation from committed exit. If preparation fails, release the barrier and restore shortcuts, sync and normal interaction. Await audio resource teardown during committed exit. Do not convert a retryable recording into a discard operation just to install an update.

Coordinate the wake helper with a local, bounded installation handoff record. It must avoid relaunching Echo during replacement, recover from a stale record, and preserve the user’s login-start preference. Exact lease lifetime and process checks need failure-injection tests; a permanent “do not launch” flag is unsuitable.

Preserve whether Echo was running quietly or had a visible window. Reopen onboarding at its durable checkpoint, recheck real permissions, and retain account/settings/library state. Do not automatically resume microphone capture after relaunch.

Sparkle’s postponement delegate alone does not cover every installation path. Combine supported updater hooks with the app’s termination/save handling, and ensure deferred installation callbacks are eventually resumed or canceled correctly. [Updater delegate contract](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)

## Security and configuration decisions

Use HTTPS, Developer ID signing/notarization and Sparkle EdDSA signatures. Embed the public update key in Echo. Keep private update keys off the CDN and separate from upload credentials, with controlled backups. Prefer a signed DMG from the first updater release: verification before extraction otherwise makes EdDSA rotation from ZIP-only delivery problematic. Change the Apple signing identity or update key one at a time. [Sparkle security and rotation guidance](https://sparkle-project.org/documentation/)

Proposed defaults: automatic checks and automatic download/install enabled, with a visible user preference; daily checks; system profiling and release-note JavaScript disabled. Enable `SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed`. Respect saved user choices. macOS authorization can still require interaction. [Configuration](https://sparkle-project.org/documentation/customization/)

Choose signed-feed failure behavior explicitly. Sparkle defaults to a restricted fallback after 20 days of signature failures; archive verification still applies. My preference is `SUSignedFeedFailureExpirationInterval=0` for indefinite rejection, conditional on tested key recovery, backups and an independent manual rescue installer. Losing the key can then require manual recovery. [Security settings](https://sparkle-project.org/documentation/customization/)

## Proposed CDN and publication contract

Main Agent confirmed these repository-backed facts; the live CDN could not be qualified from this environment because DNS resolution failed during its checks:

| Existing infrastructure | Implication for Echo |
| --- | --- |
| `https://cdn.aisha.group` fronts Nginx and S3-compatible MinIO | Underlying storage can be reused after a dedicated release route is qualified |
| Private `/backend/` media uses signed, expiring links and `private, no-store` caching | Keep it private; do not serve public installers or appcasts through this route |
| Proxy and storage remain on retained hosts separate from the current API host | Those are shared availability dependencies; an API move does not remove them |
| No confirmed Echo bucket, upload identity, public release path, purge integration or remote atomic publication | These must be configured and tested; local atomic packaging is not remote atomic publishing |
| Legacy desktop uses GitHub Releases in `voicelab-uz/desktop` | Its existing updater/website download flow does not establish native Echo CDN delivery |
| Legacy desktop CI already separates build/sign/verify from protected publication | Reuse that process pattern and a macOS signing runner; do not reuse broad media-storage credentials |

Sources: backend `docs/internal-storage-transfers.md`, `deploy/cdn-security/cdn_proxy.py`; legacy desktop `src/helpers/updateFeedConfig.js`, `.github/workflows/release-desktop.yml`; frontend `lib/desktop-releases.ts`. Main Agent identified published Electron v1.3.1, but did not establish the currently distributed native Echo version. Native project defaults are not release history.

Before implementation, confirm the public release hostname/prefix and bucket, a narrowly scoped publisher, macOS signing runner/key custody, and actual production Echo binaries. Credentials should be configured securely, not pasted into chat. The following paths are a proposal, not deployed endpoints.

Proposed paths beneath a dedicated public release namespace:

```text
echo/macos/releases/<build>/universal/
  Echo-<version>-<build>.dmg
  release.json
  SHA256SUMS.txt
  release-notes.html
echo/macos/stable/appcast.xml
echo/macos/beta/appcast.xml
```

The feed and archive downloads should not require a VoiceLab login, a live API session or expiring media URLs. Backend outages must not block distributing a repair. The Go API is optional for aggregate diagnostics or later advanced rollout controls, not a prerequisite for ordinary update checks.

Use immutable release objects with long caching and conditional creation that refuses overwrites. Use short caching/revalidation for feeds, with ETags and a tested atomic replacement mechanism. Do not rewrite signed XML/HTML at the edge. Verify Content-Length, HEAD, byte-range downloads, content types, TLS and cache behavior on the actual public route. Avoid long negative caching after failed/missing requests.

Start with full universal archives. Model capacity using active installations times compressed release size, plus retries, then spread exposure over time. A hostname called “CDN” does not prove distributed edge caching or origin redundancy. Load-test origin bandwidth and recovery, and add edge caching or a replicated origin as growth warrants it.

Publication procedure:

1. Allocate a globally increasing integer build number; build a clean pinned commit on a controlled macOS runner. Record provenance and reject dirty production sources.
2. Archive/export and validate all expected components. Notarize/staple, finalize and verify the DMG. Use the same verified artifact for test and production promotion.
3. Generate signatures, feed and release notes using pinned tooling. Sign final bytes; any later feed or notes edit requires re-signing.
4. Upload immutable artifacts first using narrowly scoped publication credentials. Fetch them through the public URL and compare against trusted build output.
5. Run signed old-to-new installation smoke tests through the beta feed.
6. Publish the stable feed last, under a concurrency lock or compare-and-swap guard. Keep prior feed revisions and release artifacts.
7. Observe failures by build, OS, CPU and stage. Promote only after the canary has passed; halt promotion on unexplained install or launch regressions.

Sparkle distinguishes the internal build number from the display version and supports OS constraints. Its phased rollout has seven time-based groups; manual checks and critical updates bypass those phases. Use a separate internal/beta feed for the initial canary. This is not an exact percentage-cohort mechanism. [Publishing rules](https://sparkle-project.org/documentation/publishing/)

Diagnostics should exclude audio, transcript contents, tokens, account identifiers and local paths. Keep updater logs bounded. Delivery of telemetry must never block installation or normal app operation. A successful installer handoff is not evidence of successful application startup; track a local post-launch completion marker as well.

## Recovery and compatibility

Offline, invalid signatures, unavailable CDN objects, malformed metadata and download interruption should leave the current app usable. Storage/authorization errors should explain the next action and preserve the installed bundle. Do not build a second ad hoc installer or delete the running bundle before validation.

A defective release is different from a failed download. Withdraw and re-sign the feed entry to stop future discovery after caches expire. This does not recall every staged or in-flight download. Release corrected code with a higher build number; keep a signed manual recovery installer available through an independent download route.

Sparkle has a separate installer architecture, but automatic rollback based on Echo’s post-launch health is not an established capability of this integration. Do not imply it has been provided. [Installer architecture](https://github.com/sparkle-project/Sparkle/blob/2.x/Documentation/Installation.md)

Current secure storage accepts schema version 1; the audit did not establish transactional schema migrations or backward data rollback. Keep the first updater releases schema-compatible. Future migrations need atomic checkpoints, recoverable prior data and interruption tests before promotion. Maintain backend compatibility for the supported older app versions throughout rollout.

Native builds that lack an updater need a one-time manual bootstrap installation. The existing Electron VoiceLab-to-native Echo transition is separate: shared bundle ID does not migrate its storage, login or recording history. Do not silently route Electron clients to native archives without a dedicated migration test and release path. Keep iOS/TestFlight distribution separate.

## Release acceptance matrix

These checks are proposed gates, **not completed test results**. Test real Developer ID signed and notarized upgrades on supported Intel and Apple Silicon Macs, including the oldest supported OS and current OS.

| Scenario | Required result |
| --- | --- |
| Recording, upload, transcription, insertion or retryable failed audio | Download allowed; automatic restart deferred; audio preserved |
| Onboarding microphone/Try it, Fn validation, permission prompt, sign-in | No interruption; correct checkpoint after relaunch |
| New work starts at the restart boundary | Exclusive barrier prevents the race; no dropped operation |
| Flush fails, Keychain is locked, auth response is lost | Restart cancels safely; app services resume; usable credentials survive |
| Pending local notes while offline | Outbox persists; no need to wait for server availability |
| CDN unavailable, TLS failure, stale/malformed feed | App stays usable; bounded background retries and useful manual feedback |
| Wrong signature, tampered feed/archive, wrong identity or incompatible OS | Reject update without modifying the installation |
| Interrupted/truncated download, low disk space, denied authorization | Clean recovery or actionable retry; no broken current install |
| Read-only DMG/translocated app, unwritable Applications directory | Explain installation/location issue without a retry loop |
| Wake/unlock, helper restart, multiple app instances | One installation; no helper launch during replacement |
| Force quit or interruption at each install stage | Valid old or new app remains launchable; local data survives |
| Signed N−2 and N−1 upgrades to candidate | Login, settings, recordings, Accessibility, microphone, shortcuts and notifications preserved |
| Non-ASCII app path, alternate user account, app running only in menu bar | Correct installation timing and restored visibility |
| Concurrent publishers, partial upload, CDN cache lag | Stable feed never points to unverified/missing bytes; no release overwrite |
| Key rotation, certificate renewal and manual rescue | Documented recovery exercised with real signatures |
| Bad startup, stopped rollout, already-staged update | Incident procedure distinguishes pending discovery from existing installs; corrective release available |

## Implementation sequence

1. Resolve production identity and publication infrastructure; inventory actually distributed native and Electron versions.
2. Implement and test the safe-restart coordinator, cancellation recovery and wake-helper handoff independently of Sparkle.
3. Add pinned Sparkle, public key/feed configuration, preference UI and gentle update status.
4. Extend release tooling with DMG packaging, nested signing checks, clean-source/build-number enforcement and signed feeds.
5. Add immutable publishing, public verification, atomic feed promotion and a documented incident procedure.
6. Run the acceptance matrix, ship the bootstrap release, then prove the next release updates it successfully before broad rollout.

The first implementation should avoid deltas, exact cohort services, custom installer code and automatic binary downgrades. Add complexity only for a measured requirement.
