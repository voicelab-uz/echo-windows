# Mac App Store readiness

Audit date: October 28, 2026. This is a source and local signing preflight, not an App Review approval or a completed Store build.

**The current full-featured Echo application is suitable for Developer ID distribution through the CDN. It is not ready for feature-equivalent Mac App Store distribution.** The Store constraints affect the product's system-wide dictation behavior, not merely signing or packaging.

## Distribution boundaries

Use the existing publishing identity, bundle identifier and notarized release workflow for the CDN build. Keep the Sparkle updater and its installer out of any future Store target; Store builds must receive updates through the Mac App Store.

Apple requires App Sandbox for Mac App Store apps. Direct distribution requires the appropriate Developer ID signing and hardened runtime for notarization; sandboxing is optional for that channel. See [Preparing your app for distribution](https://developer.apple.com/documentation/Xcode/preparing-your-app-for-distribution), [distribution signing identities](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/), and [App Review Guidelines 2.4.5](https://developer.apple.com/app-store/review/guidelines/).

## Confirmed blockers

| Area | Current implementation | Store work required |
| --- | --- | --- |
| Sandbox | Main app and EchoWakeHelper have sandboxing disabled in the Xcode project. | Create a separately audited sandboxed target/configuration with only necessary network, audio and file-access entitlements. |
| Fn policy | FnKeyPolicy dynamically calls private TISUpdateFnUsageType and modifies the HIToolbox AppleFnUsageType preference. | Remove the private API and foreign-preference modification from the Store binary; design a public-API alternative. |
| Text insertion | NativeTextInsertionEnvironment controls other applications through Accessibility APIs. | Redesign this capability for a sandbox-compatible Store edition. A permission prompt does not remove sandbox restrictions. |
| Global shortcut | GlobalShortcut requires Accessibility and a suppressing session event tap. | Validate a public, sandbox-compatible shortcut implementation. Do not assume the current bare Fn behavior can be preserved. |
| Updates | CDN builds use an independently downloaded updater. | Exclude the updater engine, installer helpers, update feed and CDN update UI from the Store product. |
| Login/helper behavior | The preflight implementation enabled login behavior by default on first installed launch and kept a helper available after the main app quit. | Require explicit consent for login and persistent helper behavior, and document what quitting does. Recheck after lifecycle changes. |

Apple specifically identifies assistive Accessibility APIs and modifying other applications' preferences as incompatible with App Sandbox. [Apple sandbox restrictions](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)

The Store rules also require public APIs, consent for background/login execution, and Store-only updates. The private API cannot be hidden or left dormant in a submitted binary. [App Review Guidelines 2.4.5, 2.5.1 and 2.5.19](https://developer.apple.com/app-store/review/guidelines/)

## Local signing preflight

A read-only signing-identity inventory confirmed the existing Developer ID Application identity for team FWCSVFT76D on this Mac. No Apple Distribution or Mac App Distribution identity appeared in that inventory. This is a local observation; it does not establish what cloud-managed signing or another CI runner can access.

The installed /Applications/Echo.app observed during preflight was a universal Intel/Apple Silicon development build, version 1.0 (1), with bundle identifier uz.voicelab.desktop and team L5FXR2YA4Q. It had get-task-allow enabled. Strict verification also reported an unexpected FinderInfo attribute on its nested EchoWakeHelper.app. This installed development copy is not a production upgrade acceptance baseline.

The existing release documentation identifies FWCSVFT76D as the publishing team for the released VoiceLab lineage using uz.voicelab.desktop. Preserve that lineage for CDN upgrades, and test permission, login, Keychain and data continuity using the final distribution-signed artifacts. See [CDN release instructions](CDN_RELEASE.md).

No certificates, private keys, permissions, installed applications or developer accounts were changed during this preflight. Notarization credentials and account access were not independently exercised.

## Remaining Store requirements

Once a Store-compatible feature set is selected:

1. Define a sandbox-compatible recording/transcription and copy/export experience; decide whether system-wide insertion is omitted. Do not promise current feature parity before a working sandboxed prototype is verified.
2. Separate Store and CDN build configuration at compile and packaging time. Check the submitted binary for private API references and excluded updater code.
3. Provision the appropriate Store distribution signing and profiles. A Developer ID certificate alone is not a Store signing identity. [Apple signing documentation](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
4. Audit container storage and migration, user-selected file access, network/microphone entitlements, login helper consent and behavior after quit.
5. Complete privacy disclosures, required privacy manifests, account-deletion and purchasing review, export-compliance information, copyright, screenshots, review credentials and submission metadata. These areas were not comprehensively audited here.
6. Test the final signed Store artifact, submit it for App Review, and resolve any review findings. A successful build or upload is not approval.

## Recommended sequence

Complete the CDN updater integration, validate signed N-to-N+1 updates through an isolated CDN test feed, then promote verified artifacts publicly. Treat a Mac App Store edition as a separate product decision and implementation effort. A reduced-capability Store edition may be feasible; this audit does not assert that Apple will approve it.
