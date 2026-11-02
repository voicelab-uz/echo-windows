# New onboarding — production handoff

Status: implemented in the actual Echo app, with automated recovery/API checks passing.
Release remains subject to the deployment and real-device acceptance checks below. No production deployment was performed.

## What ships

The app uses the same shared screens as the design preview: Welcome → Access → Setup
(microphone, physical Fn, Uzbek alphabet) → Sign In → About you → Try it → workspace.
There is no Personalize screen. The preview executable is only a design fixture.

- Microphone and Accessibility status come from macOS, never simulated grants or saved flags.
- First microphone request uses the OS prompt; denial opens the microphone settings pane.
  Restricted access explains the problem; failed Settings opening is recoverable.
- Accessibility opens the relevant System Settings pane and polls for the actual grant.
  Every onboarding step polls and foregrounding rechecks permissions. Revocation returns to Access,
  preserving the interrupted page even across a restart.
  A two-step helper beside Settings offers the current app as a file drag source, a Finder fallback,
  and an old-name hint when another installed app shares Echo's bundle identity. Only an actual OS grant dismisses it.
  The drag uses an AppKit session with the original bundle URL. SwiftUI's item-provider drag was
  creating temporary app copies, which could register an unintended bundle in Settings.
- Microphone selection persists. The setup meter uses actual PCM levels in memory; it creates no recording or upload.
- Fn validation accepts keyboard events only. The app's existing event tap owns production Fn handling;
  the focused onboarding window receives events without also starting normal dictation.
  Registration failures stay beside the key exercise with Check again and System Settings actions;
  they cannot validate the exercise or reveal Continue, and successful registration clears the error.
- Browser login uses the existing app session and Keychain. Questionnaire/STT requests bind to the expected account.
- All six context questions are optional; Next/Skip advances only after a successful server save.
  An unavailable API shows Retry instead of pretending answers were saved.
- Unsaved answers and the exact pending request/UUID are journaled in the encrypted account library.
  Disk failure prevents sending an unjournaled request. Relaunch reconciles lost responses or retries the same mutation.
  Conflicts offer reload; auth failures return to Sign In; late responses cannot update another account.
- Try it records only after an explicit Fn press, submits on the second press, and enables Next after real transcription.
  Audio capture stops on close, navigation, permission recovery, and shutdown. Temporary audio is removed after use.
- Final completion is flushed locally before opening the workspace. Its backend acknowledgement retries on launch/foreground
  after a network failure, without requiring the user to repeat setup. Local save errors keep the final page available.
- Account-scoped checkpoints restore the page and successful voice-trial milestone. Actual permission grants are always rechecked.
  Transcription text is not stored in the navigation checkpoint; history follows the existing retention preference.
- Existing completed accounts keep their completion state. DEBUG builds expose Development → Review onboarding for review;
  this does not clear history, credentials, or existing completion. Review mode is absent from Release builds.

## Backend deployment

Backend repository: `../back`. Include the questionnaire API commit `62e8293` and the subsequent
`feat(onboarding): persist final desktop onboarding completion` commit `2423b286`.
Both are currently on local branch `codex/timeout-budgets`; include them in the intended deployment branch.

1. Review and deploy only the intended backend changes; unrelated agent/billing work exists in that checkout.
2. Apply additive migrations **178** (current context + revision history) and **179** (`finished_at`)
   through the normal migration runner. These do not reset existing answers.
3. Deploy the API before distributing the updated app. No new external service or environment secret is required.
4. Verify with a desktop access token:
   - `GET /v1/desktop/onboarding/context`: absent context is `null`.
   - `PUT /v1/desktop/onboarding/context`: revision check, stable mutation UUID replay, explicit skips, saved metadata.
   - `PUT /v1/desktop/onboarding/completion` with `{}`: incomplete questionnaire is 409;
     completed questionnaire returns a stable, server-generated `finished_at` on repeated requests.
5. Verify privileged reads: `GET /api/v1/admin/onboarding/contexts` and
   `GET /api/v1/admin/users/{user_id}/onboarding/context`. The backend contract documents history pagination and SQL.

Full API contract: `../back/docs/echo-onboarding-context.md`. Questionnaire `completed_at` and full-flow
`finished_at` have distinct meanings. The backend never accepts device permission flags as proof of access.
Data is account-owned, size/choice/text bounded, revisioned, rate-limited, and protected by the existing desktop/admin auth.
Admin reads are audited without recording answer bodies in logs.

## Automated verification

Passed on 2026-10-22 (local macOS):

- `swift test --package-path Packages/VoiceLabCore`: 118 tests, including account-bound completion response validation.
- `zsh scripts/test-onboarding-completion.sh`: local-first final completion, encrypted persistence, offline pending acknowledgement,
  relaunch and subsequent API retry, plus existing completion behavior.
- `./scripts/test-onboarding-recovery.sh`: every route across restart, account isolation, denied/restricted/failed-settings behavior,
  permission revocation and return to the interrupted route, including repeated checks followed by restart at Fn.
- `./scripts/test-questionnaire.sh`: choices/skips, exact retry, conflict, stale replies, encrypted journal round trip,
  disk failure before upload, unsent edits, lost-response reconciliation, Back with an unfinished later answer.
- `./scripts/test-try-it.sh`: auth, actual capture lifecycle, device selection, cancellation, one upload, failures and cleanup.
- `./scripts/test-setup-microphone.sh`: real-level metering model, device/retry behavior and capture cancellation.
- `./scripts/test-setup-shortcut.sh`: Fn only, focus loss, key-up, held/repeated presses and retained validation.
- `zsh scripts/test-application-drag.sh`: real AppKit pasteboard round trip preserves the original app URL,
  including spaces/apostrophes; no file promise; the source accepts dragging from an inactive panel.
- `python3 scripts/test-onboarding-resources.py`: five complete catalogs, 16 languages, seven Manrope weights and license.
  Also run against the built app's `Contents/Resources` to catch packaging omissions.
- Backend PostgreSQL tests with `-race`: onboarding context and HTTP API suites, owner/auth isolation,
  concurrent/idempotent completion, preserving completion after later edits. Used a disposable local database.
- Backend API package compilation and Xcode Debug/Release app builds; standalone preview build.

Latest Accessibility/Fn recovery changes: Xcode Debug build, recovery and shortcut regressions,
16-language resources, and `scripts/test-session-routing.sh` passed. Real-device inspection found
that the current development app shares `uz.voicelab.desktop` with installed VoiceLab copies;
System Settings displays the legacy VoiceLab name. An old code-signing requirement rejected the
new build until reauthorization. A subsequent system log showed that grant removed again;
Settings then showed the switch off while Setup had retained stale permission state.
Continuous permission checks now recover that case.

Subsequent device verification on 2026-10-22: Accessibility was enabled under the legacy VoiceLab name.
Echo reopened directly on the saved Fn step without a registration error. The user pressed the physical
Fn key and confirmed that both the shimmer and Continue appeared, then continued to About you.
This verifies the Fn setup exercise and permission persistence for the current signed build; it does not
replace the broader capture/start-stop and release-signing checks below.

Branding follow-up on 2026-10-22: the built bundle already names Echo and contains the Echo icon.
An installed `/Applications/VoiceLab.app` and an older Electron build share `uz.voicelab.desktop`;
Launch Services initially preferred the installed VoiceLab. Refreshing registration and re-adding
the current Echo permission entry retained access but did not clear the legacy Settings branding.
Do not change the bundle ID or reset user data to fix this cosmetic conflict. The release upgrade
must leave one installed app for this identity, as described in `CDN_RELEASE.md`.

The native drag correction passed its pasteboard regression, an actual drag into a local receiver
showed the original Echo URL (not a cache copy), and the signed Debug app rebuilt successfully.
After reopening, onboarding resumed on About you with real permission checks still passing.
With the user's approval, both older installed bundles were backed up and the verified current
development build was installed at `/Applications/Echo.app`. ZIP backups remain at
`.build/branding-backup/VoiceLab-1.3.1.zip` and `.build/branding-backup/Echo-previous.zip`.
Archive integrity and the original regular-file contents were verified before removing the expanded
backup bundles: System Settings follows moved bundles, even with a non-app filename extension.
Account libraries, preferences and Keychain entries were not removed or reset.

Stale Launch Services registrations for the development/SwiftUI drag copies were removed without
deleting those app files. macOS now resolves `uz.voicelab.desktop` to `/Applications/Echo.app`.
The installed bundle passed strict code-signature verification, reopened on the saved About you
step, and System Settings visibly shows **Echo, the correct Echo icon, and its enabled permission switch**.
This is the development build, not a notarized release distribution. Re-launching another legacy
build with the same identifier can reintroduce competing registration metadata.

The next blocker is deployed onboarding API availability. On 2026-10-22 Echo logged HTTP 400 for
`GET /v1/desktop/onboarding/context`. A credential-free probe returned HTML 400 from release
`ci-39456016905-1`, while `/v1/desktop/me` correctly returned JSON 401 `invalid_desktop_token`.
This is consistent with the new route not reaching its Go handler; inspect deployment/proxy routing
alongside including the two API commits and migrations above. After deployment, the unauthenticated
context route must return the JSON auth error, and an authenticated request must return a context envelope.
Do not treat the HTML failure as an empty profile or bypass the save requirement.

## Device and deployed-service acceptance — still required

Use the normally signed app with its stable bundle identity, not an ad-hoc design preview. Do not reset permissions
or delete an existing user's library just to exercise first-run behavior; use a dedicated test macOS account/install.

- [ ] Fresh launch: language menu, fonts, Back alignment, scrolling at minimum window size, keyboard navigation and reduced motion.
- [ ] Microphone: Allow, Deny → Settings → Allow, restricted access, selected USB/Bluetooth input and unplug/reconnect.
- [ ] Accessibility: real Settings grant, cancellation, revoke/regrant. If macOS asks to quit, reopen and confirm the same page returns.
- [ ] Quit/reopen at microphone, Fn, alphabet, sign-in, each questionnaire question, and after a successful voice trial.
- [ ] Physical Fn: single press starts/stops exactly once; no emoji/dictation overlap; focus loss stops trial capture.
  If the existing Fn system-policy bridge cannot apply on the OS version, set the Globe/Fn action to Do Nothing in Keyboard settings.
- [ ] Browser login/cancel/expired session using the deployed API; switching accounts never reuses another account's answers/trial state.
- [ ] Real voice transcription: quiet audio, normal speech, quota/rate-limit error, interrupted network, cancel during upload.
- [ ] Questionnaire save/retry after network loss; verify current profile, revision history and final `finished_at` in backend admin reads.
- [ ] Quit immediately after Next; reopen into the workspace with completion acknowledgement eventually synced.
- [ ] Release signing/notarization and supported macOS versions under the project's normal release process.

Onboarding has 16 language catalogs. The existing workspace has English, Uzbek and Russian catalogs;
other onboarding choices currently fall back to English after onboarding. Native OS prompts follow macOS's own language.

The implemented safeguards reduce failure modes; automated tests cannot guarantee that onboarding never breaks.
Real OS permission dialogs, physical hardware, signing identity, and deployed login/STT must complete this acceptance pass.
