# Native notifications release verification

Echo **1.0.0 (115)** is published on the public stable channel and installed on the test Mac. The production website points to the same verified universal DMG. These checks do not constitute a guarantee against every crash or operating-system failure.

## Signed builds

Builds 110 and 111 use source `2ca020b78ed0ccf74f7d9d6e5943510bbb5eecb8`. Build 112 uses `8faf8f12c7db70b161cc7565ef8eb4941b2fb362`, including the simplified explicit notification-permission action. All three passed universal arm64/x86_64 packaging, strict signatures, app and DMG notarization, staples, and Gatekeeper checks. The app carries the production APNs entitlement and the exact validated Developer ID profile. The helper does not gain push or Keychain-sharing entitlements.

Build 112's DMG SHA-256 is `7e8cc841c566b5e96ef7f353f89725b70e6c339de15799d7a43cd262b56077d8`. Test feed publication is independently verified after upload; a CDN propagation delay is retried with the same publication, never a replacement artifact.

## Real local update notification: passed, October 29, 2026

1. Installed signed test build 110 at `/Applications/Echo.app` with the same designated requirement as stable 108. The existing account restored.
2. Enabled Echo's requested macOS notification permission in System Settings. Updates, Important alerts, and News were all enabled. Startup did not request permission.
3. Temporarily disabled automatic downloads for the available-update test. With Echo quit, saved only `SULastCheckTime`, preserving its type or absence, and removed that key using Sparkle's documented scheduled-check testing procedure. No account data or notification deduplication keys were reset.
4. Started Echo with its existing background-return flag. The scheduled check found signed test build 111. Notification Center contained an actual `AXNotificationCenterBanner`: “Echo 2.0.0 is available” / “Open Echo to review the update. Your work will stay protected.”
5. Quit Echo normally and verified no Echo process remained and the installed app was still build 110. The delivered notification remained visible in Notification Center.
6. Clicked that notification. It cold-launched `/Applications/Echo.app` and opened one native Software Update review for 111, while the installed app remained 110. Clicking a notification did not install anything.
7. Restored automatic downloads to their original enabled state. Explicitly chose Install Update, then Install and Relaunch after download completed. The running app and installed bundle became build 111; strict deep signature verification passed.
8. Quit normally and restored the original `SULastCheckTime`. Automatic downloads remained enabled.

The delivered-notification preferences were checked only as supporting submission evidence; the actual native banner and update-review window were independently observed through macOS Accessibility.

## Automatic-download notice and quit installation: passed

On signed build 111, automatic downloads were enabled. A second separately backed-up check timestamp triggered the normal scheduled check for test build 112. The actual macOS notification said “Echo 2.0.0 is ready to install.” Clicking it while Echo was running opened one native review with automatic downloads still enabled and Install on Quit / Install and Relaunch choices. The installed bundle remained 111. Choosing Install on Quit and then quitting Echo normally installed 112. Strict deep signatures passed, the check timestamp was restored, and Echo reopened from `/Applications/Echo.app`.

## Production provider and preferences: passed

Backend Stage A, source `f73a35e8fdc0d83dcdc0798519eb022a87bdf5d0`, passed the full manual pipeline [40789298960](https://github.com/voicelab-uz/back/actions/runs/40789298960), including expansion migrations, and adopted `desktop_push_version: 2`. The separate API-only configuration release `20261029001112-f73a35e8fdc0-config` activated Echo's provider using the existing server-owned worker policy. Both API replicas finished healthy; the monotonic topic guard and recovery timer are active, with no pending transaction.

The signed client received an OS APNs token and registered successfully after activation. A server-side aggregate scoped to the consenting account confirmed one fresh active device for `uz.voicelab.desktop`, `production`, with Important and News enabled. The query exposed no device tokens or session identifiers. Turning News off in the actual app persisted `important=true, news=false`; restoring it persisted both true. All three app categories and automatic downloads were left enabled.

## Private production push delivery: passed, October 29, 2026

With explicit approval, admin commit `0da397fc2f0eadef0088dbc2411eeab2967fcedd` was deployed to `adminjon.voicelab.uz`. Deployment passed 515 tests, a production build, rollback rehearsal, 20 recovery-policy checks, public health/sign-in checks and revision checks for 26 static assets. The prior deployment remains available for rollback.

Exactly two test campaigns were submitted through the deployed review-and-confirm UI, both with `audience=user`, the consenting account, and `environment=production`. No broad-audience campaign was sent by this test:

- Important, campaign `004fb157-39f8-4987-b79b-dab467b5cade`, created `2026-10-29T07:42:08Z`: one device, one APNs acceptance on the first attempt, zero failures, invalid tokens, uncertain deliveries or skips. Echo was quit and its process absent before sending. The exact title and body appeared in native Notification Center. Clicking that delivered notification cold-launched the installed signed app into General Settings, restored its account, and made the inbox message visible.
- News, campaign `8e8ebb46-9609-4bd5-9617-d6f33ac1fd96`, created `2026-10-29T07:53:06Z`: News was disabled in Echo, then the server confirmed `important=true, news=false` before submission. One device was skipped, zero APNs requests were accepted, and failures/invalid/uncertain counts were zero. The exact message still appeared in Echo's inbox while News remained off; no corresponding native alert appeared. A delivery attempt here means a queue claim, not an APNs send.

Backend verification was scoped to these campaign IDs and the consenting account, selecting aggregate delivery and inbox state without device tokens or session identifiers. All three notification categories were restored to enabled in Echo after the tests; the backend confirmed Important and News enabled at `2026-10-29T07:56:21Z`. Temporary recipient-ID files and test screenshots were removed. Existing account data and campaign audit records were preserved.

## Superseded stable candidate, not published

Echo **2.0.1 (114)** was built from clean source `e00a5fe284bbe5a682063c689997b52007995a41`, using the same app code as tested build 112. Its universal DMG passed signatures, notarization, staples, and Gatekeeper checks. Size: 12,487,868 bytes; SHA-256: `3005cb2c60cca5467eac59272335b84b9cb2732e444c8a0cfbd0e82b7130cbb2`. App notarization: `5426eb46-04f1-4fae-8394-ef1f5a633426`; DMG notarization: `d6605633-6578-4996-8706-b8d72e12d812`.

The signed publication plan and release notes remain local and must not be published. The requested launch version is now **1.0.0**, with internal build **115** remaining newer than every published build. Both 2.0.0 (113) and 2.0.1 (114) were superseded before publication. The replacement 1.0.0 (115) candidate passed the remote delivery checks and was subsequently published. Builds 113 and 114 remain unpublished.

The existing `https://echo.voicelab.uz/` download page returns the universal DMG; `https://voicelab.uz/echo` permanently redirects there. Both routes were checked on October 29, 2026. Final launch checks repeated them against the actual 1.0.0 artifact, as recorded below. Feed preparation now defaults to three stable releases and one per beta/test channel, ordered by numeric build. It refuses automatic pruning of unsupported compatibility constraints or the last release supporting an older macOS version. Website fallback protection and storage deletion are separately verified before cleanup.

## Public launch 1.0.0 (115): passed

Clean source `27b300c11bd8941d67368d6d8714e306ed360fe3` produced the universal arm64/x86_64 DMG. App and DMG signatures, notarization, staples, mounted installer layout and Gatekeeper validation passed. App notarization: `e839eef0-de9d-4665-bc7b-266a8e143d5c`; DMG notarization: `3d5908b3-238f-4abe-9135-437c6f345359`. The DMG is 12,487,273 bytes; SHA-256: `9b0d4dc03297e00b19554e38abd650804674791db3580befc2da057e4837de29`.

The local `dist/publication-115` plan passed validation of all five files, archive/notes/feed signatures, clean provenance, and the previous-feed compare-and-swap binding. Its manifest SHA-256 is `761ed690124e3348b3eabe551006e23bda71225037eb5b0feda26f9b3dd57cd8`. The exact prepared publication was later promoted without replacing its artifacts. The native Sparkle regression confirms build 115 outranks installed builds 108 and 112 while displaying version 1.0.0. Packaging/publication/retention suites passed 120 cases, with separate native updater lifecycle checks.

Frontend commit `728446462bd47fa6c8a59343efd3751b6cc949a2` deployed through [workflow 40795664446](https://github.com/voicelab-uz/frontend/actions/runs/40795664446). Both public protection endpoints return direct 200 with `Cache-Control: no-store`, protecting the verified stable-2.0.0-108 fallback. Echo homepage download and `/echo` redirect checks passed after deployment. Frontend checks passed 1,059 unit tests, 19 deployment tests, full TypeScript checking and production build. After verifying the actual public release/asset IDs, bytes and checksum, the fallback advanced to build 115 in the final deployment below.

The live read-only retention plan SHA-256 is `6a0ab137ca93cdad4fde93508b7eac0a6c8c135edc5d4480e766ed9d5ebe80d7`. It preserves all ten current releases (one stable, nine test), with zero deletions: existing signed feeds still reference them. Total assets are 124,090,485 bytes on GitHub, not the production server. Future feed preparation and automatic post-publication retention bound new releases; the legacy test-feed references remain protected until that channel advances. No live cleanup mutation was performed.

Physical Intel/macOS 14 runtime, destructive power loss, and low-disk scenarios were not exercised on this Mac.


### Publication and final website deployment

Published `stable-1.0.0-115` at `2026-10-29T07:57:05Z`: immutable public GitHub release `427589166`, universal DMG asset `687798377`. The publisher verified all public assets before updating the signed stable feed and independently verified that public feed afterward. The final retention plan `c1c2eda7da19eff2ce45f60df96c7d6ecc1a979f0c17b07a2d3dd1153ee2c0d4` safely deleted zero releases. The two stable releases are below the three-release limit; legacy test releases remain protected by the existing signed test feed.

Frontend commit `32a9a541994be7ac9d91c4bd91308d604fa0c918` deployed successfully in [workflow 40839558486](https://github.com/voicelab-uz/frontend/actions/runs/40839558486), deployment ID `ci-32a9a541994b-40839558486-1`. Both live protection URLs return direct HTTP 200 with `Cache-Control: no-store`, no `Age`, and only `stable-1.0.0-115` protected. `https://echo.voicelab.uz/` and `https://voicelab.uz/download` return 200 and link to the exact 1.0.0 universal DMG; `https://voicelab.uz/echo` returns 308 to the Echo host. Linux links remain intact. A separate public download returned HTTP 200, 12,487,273 bytes and the expected SHA-256. Frontend validation passed 1,059 unit tests, 19 deployment tests, TypeScript/type generation, production build, design lint, targeted ESLint and formatting.

### Browser download and Finder installation: passed

Downloaded the public 115 DMG using Chrome. Its macOS quarantine and download-origin metadata were present, and its SHA-256 matched the published artifact. Mounted the downloaded image, verified Finder's front window targeted that volume, and dragged Echo onto its Applications shortcut. Backed up the prior signed 112 app before choosing Replace in Finder.

The installed bundle reports version 1.0.0/build 115. Strict deep signature verification passed and Gatekeeper accepted it as Notarized Developer ID. Opened the installed app and confirmed the normal macOS downloaded-app prompt, which stated that Apple checked the file and detected no malicious software. After choosing Open, Echo ran directly from `/Applications/Echo.app/Contents/MacOS/Echo`, without app translocation.

The account restored. Settings showed Echo 1.0.0, and Check for Updates reported “Echo 1.0.0 is currently the newest version available.” Automatic checking and automatic installation remained enabled. All three notification preferences remained enabled, both private inbox test messages persisted, and the Permissions screen reported Accessibility enabled. No additional push campaign was sent during this final installation check.
